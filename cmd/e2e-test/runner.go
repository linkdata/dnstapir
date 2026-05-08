package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	defaultNATSServerVersion = "v2.12.7"
	defaultEDMKID            = "e2e-edm"
	defaultBridgeKID         = "e2e-bridge"
)

type e2ePaths struct {
	root     string
	upstream string
	work     string
	bin      string
	tools    string
	log      string
	conf     string
	keys     string
	results  string
	edmData  string
	goCache  string
	goMod    string
	fixture  string
}

type e2eRunner struct {
	paths             e2ePaths
	natsServerVersion string
	natsServerBin     string
	mqttPort          int
	natsPort          int
	edmDNSTAPPort     int
	edmMetricsPort    int
	manualRotation    bool
	mqttURL           string
	natsURL           string
	edmKID            string
	bridgeKID         string
	popRepo           string

	mu          sync.Mutex
	processes   []*startedProcess
	cleanupOnce sync.Once
}

type startedProcess struct {
	name string
	cmd  *exec.Cmd
}

func runE2E(args []string) error {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	rootFlag := fs.String("root", "", "repository root; defaults to auto-detection")
	workFlag := fs.String("workdir", os.Getenv("E2E_WORKDIR"), "work directory")
	popRepoFlag := fs.String("pop-repo", os.Getenv("E2E_POP_REPO"), "POP checkout to use for direct RPZ verification")
	natsBinFlag := fs.String("nats-server", os.Getenv("E2E_NATS_SERVER"), "nats-server binary")
	natsVersionFlag := fs.String("nats-server-version", getenvDefault("E2E_NATS_SERVER_VERSION", defaultNATSServerVersion), "nats-server version to install when needed")
	mqttPortFlag := fs.Int("mqtt-port", getenvInt("E2E_MQTT_PORT", 0), "MQTT listen port; 0 chooses a free port")
	natsPortFlag := fs.Int("nats-port", getenvInt("E2E_NATS_PORT", 14222), "NATS listen port")
	edmDNSTAPPortFlag := fs.Int("edm-dnstap-port", getenvInt("E2E_EDM_DNSTAP_PORT", 53535), "EDM DNSTAP listen port")
	manualRotationFlag := fs.Bool("manual-parquet-rotation", getenvBool("E2E_MANUAL_PARQUET_ROTATION", true), "request immediate EDM parquet rotation after fixture injection")
	if err := fs.Parse(args); err != nil {
		return err
	}

	root := *rootFlag
	var err error
	if root == "" {
		root, err = detectRepoRoot()
		if err != nil {
			return err
		}
	}
	root, err = filepath.Abs(root)
	if err != nil {
		return err
	}
	work := *workFlag
	if work == "" {
		work = filepath.Join(root, ".e2e-work")
	}
	work, err = filepath.Abs(work)
	if err != nil {
		return err
	}

	mqttPort := *mqttPortFlag
	if mqttPort == 0 {
		mqttPort, err = chooseFreePort(28884)
		if err != nil {
			return err
		}
	}

	r := &e2eRunner{
		paths: e2ePaths{
			root:     root,
			upstream: filepath.Join(root, "upstream"),
			work:     work,
			bin:      filepath.Join(work, "bin"),
			tools:    filepath.Join(work, "tools"),
			log:      filepath.Join(work, "logs"),
			conf:     filepath.Join(work, "conf"),
			keys:     filepath.Join(work, "keys"),
			results:  filepath.Join(work, "results"),
			edmData:  filepath.Join(work, "edm-data"),
			goCache:  filepath.Join(work, "gocache"),
			goMod:    getenvDefault("E2E_GOMODCACHE", filepath.Join(work, "gomodcache")),
			fixture:  filepath.Join(root, "fixtures", "dnstap-fixtures.json"),
		},
		natsServerVersion: *natsVersionFlag,
		natsServerBin:     *natsBinFlag,
		mqttPort:          mqttPort,
		natsPort:          *natsPortFlag,
		edmDNSTAPPort:     *edmDNSTAPPortFlag,
		edmMetricsPort:    2112,
		manualRotation:    *manualRotationFlag,
		mqttURL:           fmt.Sprintf("mqtt://127.0.0.1:%d", mqttPort),
		natsURL:           fmt.Sprintf("nats://127.0.0.1:%d", *natsPortFlag),
		edmKID:            defaultEDMKID,
		bridgeKID:         defaultBridgeKID,
		popRepo:           *popRepoFlag,
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(signals)
	go func() {
		sig := <-signals
		r.logf("received %s; cleaning up", sig)
		r.cleanup()
		os.Exit(128 + signalNumber(sig))
	}()
	defer r.cleanup()

	return r.run()
}

func (r *e2eRunner) run() error {
	if _, err := exec.LookPath("go"); err != nil {
		return errors.New("missing required command: go")
	}
	if err := r.checkUpstreamRepos(); err != nil {
		return err
	}
	if err := r.resetWorkdir(); err != nil {
		return err
	}
	if err := r.ensureNATSServer(); err != nil {
		return err
	}
	if err := r.buildBinaries(); err != nil {
		return err
	}
	if r.manualRotation {
		if err := r.requireEDMManualRotationSupport(); err != nil {
			return err
		}
	}
	if err := runKeygen([]string{"--dir", r.paths.keys, "--edm-kid", r.edmKID, "--bridge-kid", r.bridgeKID}); err != nil {
		return err
	}
	if err := r.writeConfigs(); err != nil {
		return err
	}
	if err := r.compileDAWG(); err != nil {
		return err
	}
	if err := r.startServices(); err != nil {
		return err
	}
	if err := runMQTTPublish([]string{
		"--server", r.mqttURL,
		"--topic", "events/up/" + r.edmKID + "/new_qname",
		"--payload-file", filepath.Join(r.paths.conf, "unsigned-new-qname.json"),
	}); err != nil {
		return err
	}
	if err := r.startCapturesAndEDM(); err != nil {
		return err
	}
	if err := runInject([]string{
		"--fixture", r.paths.fixture,
		"--target", fmt.Sprintf("tcp://127.0.0.1:%d", r.edmDNSTAPPort),
		"--out", filepath.Join(r.paths.results, "inject.json"),
	}); err != nil {
		return err
	}
	if err := waitFiles(90*time.Second,
		filepath.Join(r.paths.results, "upbound-new-qname.json"),
		filepath.Join(r.paths.results, "downbound-observation.json"),
	); err != nil {
		return err
	}
	if r.manualRotation {
		if err := r.requestEDMParquetRotation(); err != nil {
			return err
		}
	}
	if err := r.runPopDriver(); err != nil {
		return err
	}
	parquetTimeout := "75s"
	if r.manualRotation {
		parquetTimeout = "15s"
	}
	if err := runParquetCheck([]string{
		"--fixture", r.paths.fixture,
		"--data-dir", r.paths.edmData,
		"--timeout", parquetTimeout,
		"--out", filepath.Join(r.paths.results, "parquet.json"),
	}); err != nil {
		return err
	}
	summaryPath := filepath.Join(r.paths.results, "summary.json")
	if err := runSummarize([]string{
		"--inject", filepath.Join(r.paths.results, "inject.json"),
		"--upbound", filepath.Join(r.paths.results, "upbound-new-qname.json"),
		"--downbound", filepath.Join(r.paths.results, "downbound-observation.json"),
		"--pop", filepath.Join(r.paths.results, "pop-artifact.json"),
		"--parquet", filepath.Join(r.paths.results, "parquet.json"),
		"--out", summaryPath,
	}); err != nil {
		return err
	}
	r.logf("summary written to %s", summaryPath)
	body, err := os.ReadFile(summaryPath)
	if err != nil {
		return err
	}
	_, err = os.Stdout.Write(body)
	return err
}

func (r *e2eRunner) checkUpstreamRepos() error {
	for _, repo := range []string{"edm", "cli", "mqtt-bridge", "tapir-analyse-new-qname", "observation-encoder"} {
		path := filepath.Join(r.paths.upstream, repo)
		if info, err := os.Stat(path); err != nil || !info.IsDir() {
			return fmt.Errorf("missing upstream checkout: %s", path)
		}
	}
	return nil
}

func (r *e2eRunner) resetWorkdir() error {
	for _, path := range []string{
		r.paths.bin,
		r.paths.log,
		r.paths.conf,
		r.paths.keys,
		r.paths.results,
		r.paths.edmData,
		filepath.Join(r.paths.work, "nats"),
		r.paths.goCache,
	} {
		if err := os.RemoveAll(path); err != nil {
			return err
		}
	}
	for _, path := range []string{r.paths.bin, r.paths.tools, r.paths.log, r.paths.conf, r.paths.keys, r.paths.results, r.paths.edmData} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			return err
		}
	}
	return nil
}

func (r *e2eRunner) ensureNATSServer() error {
	if r.natsServerBin != "" {
		return nil
	}
	candidate := filepath.Join(r.paths.tools, "nats-server")
	if isExecutable(candidate) {
		r.natsServerBin = candidate
		return nil
	}
	if path, err := exec.LookPath("nats-server"); err == nil {
		r.natsServerBin = path
		return nil
	}
	r.natsServerBin = candidate
	r.logf("installing nats-server %s into %s", r.natsServerVersion, r.paths.tools)
	return r.runCommand("", r.goEnv("GOBIN="+r.paths.tools), "go", "install", "github.com/nats-io/nats-server/v2@"+r.natsServerVersion)
}

func (r *e2eRunner) buildBinaries() error {
	builds := []struct {
		name string
		dir  string
		pkg  string
	}{
		{"e2e-test", r.paths.root, "./cmd/e2e-test"},
		{"dnstapir-edm", filepath.Join(r.paths.upstream, "edm"), "./cmd/dnstapir-edm"},
		{"dnstapir-cli", filepath.Join(r.paths.upstream, "cli"), "."},
		{"mqtt-bridge", filepath.Join(r.paths.upstream, "mqtt-bridge"), "./cmd/mqtt-bridge"},
		{"tapir-analyse-new-qname", filepath.Join(r.paths.upstream, "tapir-analyse-new-qname"), "./cmd/tapir-analyse-new-qname"},
		{"observation-encoder", filepath.Join(r.paths.upstream, "observation-encoder"), "./cmd/observation-encoder"},
	}
	for _, b := range builds {
		r.logf("building %s", b.name)
		if err := r.runCommand(b.dir, r.goEnv(), "go", "build", "-o", filepath.Join(r.paths.bin, b.name), b.pkg); err != nil {
			return err
		}
	}
	return nil
}

func (r *e2eRunner) compileDAWG() error {
	return r.runCommand("", nil,
		filepath.Join(r.paths.bin, "dnstapir-cli"),
		"--standalone", "dawg", "compile",
		"--format", "csv",
		"--src", filepath.Join(r.paths.conf, "tiny-domains.csv"),
		"--dawg", filepath.Join(r.paths.conf, "well-known-domains.dawg"),
	)
}

func (r *e2eRunner) requireEDMManualRotationSupport() error {
	out, err := r.commandOutput("", nil, filepath.Join(r.paths.bin, "dnstapir-edm"), "run", "--help")
	if err != nil {
		return err
	}
	if !strings.Contains(string(out), "--enable-manual-parquet-rotation") {
		return errors.New("EDM binary does not support --enable-manual-parquet-rotation; update upstream/edm or run with --manual-parquet-rotation=false to use minute-boundary rotation")
	}
	return nil
}

func (r *e2eRunner) startServices() error {
	if err := r.startProcess("nats", nil, r.natsServerBin, "-js", "-p", strconv.Itoa(r.natsPort), "-sd", filepath.Join(r.paths.work, "nats")); err != nil {
		return err
	}
	if err := waitPort(r.natsPort, 30*time.Second); err != nil {
		return fmt.Errorf("timed out waiting for nats on port %d: %w", r.natsPort, err)
	}
	if err := r.startProcess("mqtt-broker", nil, filepath.Join(r.paths.bin, "e2e-test"), "mqtt-broker", "--addr", fmt.Sprintf("127.0.0.1:%d", r.mqttPort)); err != nil {
		return err
	}
	if err := waitPort(r.mqttPort, 30*time.Second); err != nil {
		return fmt.Errorf("timed out waiting for mqtt-broker on port %d: %w", r.mqttPort, err)
	}
	if err := r.startProcess("mqtt-bridge", nil, filepath.Join(r.paths.bin, "mqtt-bridge"), "-config-file", filepath.Join(r.paths.conf, "mqtt-bridge.toml")); err != nil {
		return err
	}
	if err := r.startProcess("analyzer", nil, filepath.Join(r.paths.bin, "tapir-analyse-new-qname"), "-config", filepath.Join(r.paths.conf, "analyzer.toml")); err != nil {
		return err
	}
	if err := r.startProcess("observation-encoder", nil, filepath.Join(r.paths.bin, "observation-encoder"), "-config", filepath.Join(r.paths.conf, "observation-encoder.toml")); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	return nil
}

func (r *e2eRunner) startCapturesAndEDM() error {
	if err := r.startProcess("capture-upbound", nil,
		filepath.Join(r.paths.bin, "e2e-test"), "mqtt-capture",
		"--server", r.mqttURL,
		"--topic", "events/up/"+r.edmKID+"/new_qname",
		"--verify-key", filepath.Join(r.paths.keys, "edm-jws-public.json"),
		"--out", filepath.Join(r.paths.results, "upbound-new-qname.json"),
		"--timeout", "75s",
	); err != nil {
		return err
	}
	if err := r.startProcess("capture-downbound", nil,
		filepath.Join(r.paths.bin, "e2e-test"), "mqtt-capture",
		"--server", r.mqttURL,
		"--topic", "observations/down/tapir-pop",
		"--verify-key", filepath.Join(r.paths.keys, "bridge-jws-public.json"),
		"--out", filepath.Join(r.paths.results, "downbound-observation.json"),
		"--timeout", "75s",
	); err != nil {
		return err
	}
	edmArgs := []string{
		"run",
		"--input-tcp", fmt.Sprintf("127.0.0.1:%d", r.edmDNSTAPPort),
		"--data-dir", r.paths.edmData,
		"--config-file", filepath.Join(r.paths.conf, "edm.toml"),
		"--well-known-domains-file", filepath.Join(r.paths.conf, "well-known-domains.dawg"),
		"--disable-histogram-sender",
		"--disable-mqtt-filequeue",
		"--mqtt-server", r.mqttURL,
		"--mqtt-client-cert-file", filepath.Join(r.paths.keys, "client.crt"),
		"--mqtt-client-key-file", filepath.Join(r.paths.keys, "client.key"),
		"--mqtt-signing-key-file", filepath.Join(r.paths.keys, "edm-jws.json"),
	}
	if r.manualRotation {
		edmArgs = append(edmArgs, "--enable-manual-parquet-rotation")
	}
	if err := r.startProcess("edm", []string{"DEBUG=false"}, filepath.Join(r.paths.bin, "dnstapir-edm"), edmArgs...); err != nil {
		return err
	}
	if err := waitPort(r.edmDNSTAPPort, 30*time.Second); err != nil {
		return fmt.Errorf("timed out waiting for edm-dnstap on port %d: %w", r.edmDNSTAPPort, err)
	}
	if err := waitPort(r.edmMetricsPort, 30*time.Second); err != nil {
		return fmt.Errorf("timed out waiting for edm-metrics on port %d: %w", r.edmMetricsPort, err)
	}
	return nil
}

func (r *e2eRunner) requestEDMParquetRotation() error {
	url := fmt.Sprintf("http://127.0.0.1:%d/debug/rotate-parquet", r.edmMetricsPort)
	r.logf("requesting EDM parquet rotation")
	req, err := http.NewRequest(http.MethodPost, url, nil)
	if err != nil {
		return err
	}
	client := http.Client{Timeout: 15 * time.Second}
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("request EDM parquet rotation: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusAccepted {
		body, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
		return fmt.Errorf("request EDM parquet rotation: status %s: %s", res.Status, strings.TrimSpace(string(body)))
	}
	return nil
}

func (r *e2eRunner) runPopDriver() error {
	popRepo := r.resolvePopRepo()
	if info, err := os.Stat(popRepo); err != nil || !info.IsDir() {
		return fmt.Errorf("missing POP checkout: %s", popRepo)
	}
	popTmp := filepath.Join(r.paths.work, "pop-driver")
	if err := os.RemoveAll(popTmp); err != nil {
		return err
	}
	if err := os.MkdirAll(popTmp, 0o755); err != nil {
		return err
	}
	pkgName, err := r.popPackageName(popRepo)
	if err != nil {
		return err
	}
	if pkgName == "pop" {
		goMod := fmt.Sprintf(`module dnstapir-pop-e2e-driver

go 1.24.0

require dnstapir-pop v0.0.0

replace dnstapir-pop => %s
`, popRepo)
		if err := os.WriteFile(filepath.Join(popTmp, "go.mod"), []byte(goMod), 0o644); err != nil {
			return err
		}
		if err := copyFile(filepath.Join(r.paths.root, "popdriver", "pop_e2e_package_driver_test.go.tmpl"), filepath.Join(popTmp, "pop_e2e_driver_test.go")); err != nil {
			return err
		}
		if fileExists(filepath.Join(popRepo, "go.sum")) {
			if err := copyFile(filepath.Join(popRepo, "go.sum"), filepath.Join(popTmp, "go.sum")); err != nil {
				return err
			}
		}
		if err := r.runCommand(popTmp, r.goEnv(), "go", "mod", "tidy"); err != nil {
			return err
		}
	} else {
		goFiles, err := filepath.Glob(filepath.Join(popRepo, "*.go"))
		if err != nil {
			return err
		}
		for _, src := range goFiles {
			if err := copyFile(src, filepath.Join(popTmp, filepath.Base(src))); err != nil {
				return err
			}
		}
		for _, name := range []string{"go.mod", "go.sum"} {
			if err := copyFile(filepath.Join(popRepo, name), filepath.Join(popTmp, name)); err != nil {
				return err
			}
		}
		if err := copyFile(filepath.Join(r.paths.root, "popdriver", "pop_e2e_driver_test.go.tmpl"), filepath.Join(popTmp, "pop_e2e_driver_test.go")); err != nil {
			return err
		}
	}
	return r.runCommand(popTmp, r.goEnv(
		"E2E_POP_OBSERVATION="+filepath.Join(r.paths.results, "downbound-observation.json"),
		"E2E_POP_ARTIFACT="+filepath.Join(r.paths.results, "pop-artifact.json"),
		"E2E_POP_FORBIDDEN_DOMAIN=unsigned-rpz-e2e.invalid.",
	), "go", "test", "-vet=off", "-run", "TestE2EPopArtifact", ".")
}

func (r *e2eRunner) resolvePopRepo() string {
	if r.popRepo != "" {
		return r.popRepo
	}
	sibling := filepath.Join(r.paths.root, "..", "dnstapir-pop")
	if info, err := os.Stat(sibling); err == nil && info.IsDir() {
		return sibling
	}
	return filepath.Join(r.paths.upstream, "pop")
}

func (r *e2eRunner) popPackageName(repo string) (string, error) {
	out, err := r.commandOutput(repo, r.goEnv(), "go", "list", "-f", "{{.Name}}", ".")
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

func (r *e2eRunner) writeConfigs() error {
	files := map[string]string{
		filepath.Join(r.paths.conf, "tiny-domains.csv"): `rank,domain
1,example.com
2,example.org
3,example.net
`,
		filepath.Join(r.paths.conf, "edm.toml"): `cryptopan-key = "dnstapir-e2e-key"
`,
		filepath.Join(r.paths.conf, "mqtt-bridge.toml"): fmt.Sprintf(`Debug = true
MqttUrl = "%s"
MqttCaCert = ""
MqttClientCert = ""
MqttClientKey = ""
NatsUrl = "%s"
NodemanApiUrl = "https://127.0.0.1/unused"

[[Bridges]]
Direction = "up"
MqttTopic = "events/up/%s/new_qname"
NatsSubject = "internal.events.new_qname"
NatsQueue = "new-qname-e2e"
Key = "%s"
Schema = "%s"

[[Bridges]]
Direction = "down"
MqttTopic = "observations/down/tapir-pop"
MqttRetain = false
NatsSubject = "e2e.down.tapir-pop"
NatsQueue = "tapir-pop-e2e"
Key = "%s"
Schema = "%s"
`, r.mqttURL, r.natsURL, r.edmKID, filepath.Join(r.paths.keys, "edm-jws.json"), filepath.Join(r.paths.root, "schemas", "new_qname.json"), filepath.Join(r.paths.keys, "bridge-jws.json"), filepath.Join(r.paths.root, "schemas", "edge_observations.json")),
		filepath.Join(r.paths.conf, "analyzer.toml"): fmt.Sprintf(`debug = true
ignore_suffixes = []

[nats]
debug = true
url = "%s"
event_subject = "internal.events.new_qname"
observation_subject_prefix = "internal.observations"
seen_domains_subject_prefix = "internal.seen-domains"
private_subject_prefix = "internal.service.tapir-analyse-new-qname"

[[nats.observation_buckets]]
observation = "globally_new"
name = "globally_new"
create = true
ttl = 3600

[nats.seen_domains_bucket]
name = "seen_domains"
create = true

[api]
active = false
`, r.natsURL),
		filepath.Join(r.paths.conf, "observation-encoder.toml"): fmt.Sprintf(`debug = true
ttl_margin = 5

[nats]
url = "%s"
subject_southbound = "e2e.down.tapir-pop"
observation_subject_prefix = "internal.observations"

[[nats.buckets]]
name = "globally_new"
ttl = 3600

[api]
active = false
`, r.natsURL),
		filepath.Join(r.paths.conf, "unsigned-new-qname.json"): `{"type":"new_qname","version":0,"qname":"unsigned-rpz-e2e.invalid.","qtype":1,"qclass":1,"timestamp":"2026-01-02T03:04:08Z"}
`,
	}
	for path, body := range files {
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			return err
		}
	}
	return nil
}

func (r *e2eRunner) startProcess(name string, env []string, command string, args ...string) error {
	r.logf("starting %s", name)
	logPath := filepath.Join(r.paths.log, name+".log")
	logFile, err := os.Create(logPath)
	if err != nil {
		return err
	}
	cmd := exec.Command(command, args...)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.Env = mergeEnv(os.Environ(), env...)
	configureSupervisedCommand(cmd)
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return fmt.Errorf("start %s: %w", name, err)
	}
	_ = logFile.Close()
	r.mu.Lock()
	r.processes = append(r.processes, &startedProcess{name: name, cmd: cmd})
	r.mu.Unlock()
	return nil
}

func (r *e2eRunner) cleanup() {
	r.cleanupOnce.Do(func() {
		r.mu.Lock()
		processes := append([]*startedProcess(nil), r.processes...)
		r.mu.Unlock()
		for i := len(processes) - 1; i >= 0; i-- {
			p := processes[i]
			if p.cmd.Process == nil {
				continue
			}
			if !stopCommandGroup(p.cmd, 5*time.Second) {
				r.logf("timed out waiting for %s to exit", p.name)
			}
		}
	})
}

func stopCommandGroup(cmd *exec.Cmd, grace time.Duration) bool {
	pgid, err := syscall.Getpgid(cmd.Process.Pid)
	if err == nil {
		_ = syscall.Kill(-pgid, syscall.SIGTERM)
	} else {
		_ = cmd.Process.Signal(syscall.SIGTERM)
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	select {
	case <-done:
		return true
	case <-time.After(grace):
	}

	if err == nil {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	} else {
		_ = cmd.Process.Kill()
	}

	select {
	case <-done:
		return true
	case <-time.After(time.Second):
		return false
	}
}

func (r *e2eRunner) runCommand(dir string, env []string, command string, args ...string) error {
	cmd := exec.Command(command, args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Env = mergeEnv(os.Environ(), env...)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", command, strings.Join(args, " "), err)
	}
	return nil
}

func (r *e2eRunner) commandOutput(dir string, env []string, command string, args ...string) ([]byte, error) {
	cmd := exec.Command(command, args...)
	cmd.Dir = dir
	cmd.Env = mergeEnv(os.Environ(), env...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%s %s: %w: %s", command, strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func (r *e2eRunner) goEnv(extra ...string) []string {
	return append([]string{
		"GOCACHE=" + r.paths.goCache,
		"GOMODCACHE=" + r.paths.goMod,
	}, extra...)
}

func (r *e2eRunner) logf(format string, args ...any) {
	fmt.Fprintf(os.Stdout, "[e2e] "+format+"\n", args...)
}

func detectRepoRoot() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}

	candidates := []string{wd}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Dir(exe))
	}
	for _, start := range candidates {
		root, ok := findRepoRootAbove(start)
		if ok {
			return root, nil
		}
	}
	return "", errors.New("unable to detect repository root; run from the repo or pass --root")
}

func findRepoRootAbove(start string) (string, bool) {
	dir, err := filepath.Abs(start)
	if err != nil {
		return "", false
	}
	for {
		if root, ok := repoRootFromCandidate(dir); ok {
			return root, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

func repoRootFromCandidate(dir string) (string, bool) {
	if fileExists(filepath.Join(dir, "go.mod")) &&
		fileExists(filepath.Join(dir, "fixtures", "dnstap-fixtures.json")) &&
		fileExists(filepath.Join(dir, "cmd", "e2e-test", "main.go")) {
		return dir, true
	}
	return "", false
}

func chooseFreePort(start int) (int, error) {
	for port := start; port < start+100; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			_ = ln.Close()
			return port, nil
		}
	}
	return 0, fmt.Errorf("unable to find a free port at or above %d", start)
}

func waitPort(port int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("port %d did not open within %s", port, timeout)
}

func waitFiles(timeout time.Duration, paths ...string) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		allReady := true
		for _, path := range paths {
			info, err := os.Stat(path)
			if err != nil || info.Size() == 0 {
				allReady = false
				break
			}
		}
		if allReady {
			return nil
		}
		time.Sleep(time.Second)
	}
	return fmt.Errorf("timed out waiting for files: %s", strings.Join(paths, ", "))
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	info, err := in.Stat()
	if err != nil {
		return err
	}
	return os.Chmod(dst, info.Mode().Perm())
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}

func getenvDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	i, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return i
}

func getenvBool(key string, fallback bool) bool {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return fallback
	}
	return b
}

func mergeEnv(base []string, extra ...string) []string {
	out := append([]string(nil), base...)
	for _, kv := range extra {
		key, _, ok := strings.Cut(kv, "=")
		if !ok {
			out = append(out, kv)
			continue
		}
		prefix := key + "="
		filtered := out[:0]
		for _, existing := range out {
			if !strings.HasPrefix(existing, prefix) {
				filtered = append(filtered, existing)
			}
		}
		out = append(filtered, kv)
	}
	return out
}

func signalNumber(sig os.Signal) int {
	if s, ok := sig.(syscall.Signal); ok {
		return int(s)
	}
	return 1
}
