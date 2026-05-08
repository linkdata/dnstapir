package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"math/big"
	"net"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	dnstap "github.com/dnstap/golang-dnstap"
	"github.com/eclipse/paho.golang/autopaho"
	"github.com/eclipse/paho.golang/paho"
	"github.com/lestrrat-go/jwx/v2/jwa"
	"github.com/lestrrat-go/jwx/v2/jwk"
	"github.com/lestrrat-go/jwx/v2/jws"
	"github.com/miekg/dns"
	mochimqtt "github.com/mochi-mqtt/server/v2"
	"github.com/mochi-mqtt/server/v2/hooks/auth"
	"github.com/mochi-mqtt/server/v2/listeners"
	"github.com/parquet-go/parquet-go"
	"google.golang.org/protobuf/proto"
)

const dnstapIdentity = "e2e-fixture-injector"

type fixtureFile struct {
	FixtureVersion int             `json:"fixture_version"`
	Description    string          `json:"description"`
	Fixtures       []fixture       `json:"fixtures"`
	NegativeMQTT   negativeMQTTDef `json:"negative_mqtt"`
}

type fixture struct {
	Name         string        `json:"name"`
	QName        string        `json:"qname"`
	QType        uint16        `json:"qtype"`
	QClass       uint16        `json:"qclass"`
	RCode        int           `json:"rcode"`
	ClientIP     string        `json:"client_ip"`
	ResolverIP   string        `json:"resolver_ip"`
	ClientPort   uint16        `json:"client_port"`
	ResolverPort uint16        `json:"resolver_port"`
	ResponseTime string        `json:"response_time"`
	Answers      []dnsAnswer   `json:"answers"`
	Expected     fixtureExpect `json:"expected"`
}

type dnsAnswer struct {
	Type  string `json:"type"`
	Name  string `json:"name"`
	Value string `json:"value"`
	TTL   uint32 `json:"ttl"`
}

type fixtureExpect struct {
	Session   bool   `json:"session"`
	Histogram bool   `json:"histogram"`
	NewQName  bool   `json:"new_qname"`
	RPZ       bool   `json:"rpz"`
	RPZAction string `json:"rpz_action"`
	RPZTarget string `json:"rpz_target"`
}

type negativeMQTTDef struct {
	Topic           string         `json:"topic"`
	Payload         map[string]any `json:"payload"`
	MustNotReachRPZ string         `json:"must_not_reach_rpz"`
}

type injectResult struct {
	DNSTAPSent int      `json:"dnstap_sent"`
	Names      []string `json:"names"`
}

type parquetResult struct {
	SessionParquetRows   int      `json:"session_parquet_rows"`
	HistogramParquetRows int      `json:"histogram_parquet_rows"`
	SessionMatched       []string `json:"session_matched"`
	HistogramMatched     []string `json:"histogram_matched"`
	SessionFiles         []string `json:"session_files"`
	HistogramFiles       []string `json:"histogram_files"`
}

type popArtifactSummary struct {
	Domain     string         `json:"domain"`
	ListType   string         `json:"list_type"`
	SourceName string         `json:"source_name"`
	Action     string         `json:"action"`
	RenderedRR string         `json:"rendered_rpz_rr"`
	RPZRecords []popRPZRecord `json:"rpz_records"`
}

type popRPZRecord struct {
	Domain     string `json:"domain"`
	Action     string `json:"action"`
	RenderedRR string `json:"rendered_rpz_rr"`
}

type harnessSummary struct {
	DNSTAPSent           int             `json:"dnstap_sent"`
	MQTTNewQNameSeen     int             `json:"mqtt_new_qname_seen"`
	CoreObservationsSeen int             `json:"core_observations_seen"`
	RPZRecords           []popRPZRecord  `json:"rpz_records"`
	SessionParquetRows   int             `json:"session_parquet_rows"`
	HistogramParquetRows int             `json:"histogram_parquet_rows"`
	UpboundNewQName      json.RawMessage `json:"upbound_new_qname"`
	DownboundObservation json.RawMessage `json:"downbound_observation"`
}

type sessionRow struct {
	Label0     *string `parquet:"label0"`
	Label1     *string `parquet:"label1"`
	Label2     *string `parquet:"label2"`
	Label3     *string `parquet:"label3"`
	Label4     *string `parquet:"label4"`
	Label5     *string `parquet:"label5"`
	Label6     *string `parquet:"label6"`
	Label7     *string `parquet:"label7"`
	Label8     *string `parquet:"label8"`
	Label9     *string `parquet:"label9"`
	ServerID   *string `parquet:"server_id"`
	SourcePort *int32  `parquet:"source_port"`
	DestPort   *int32  `parquet:"dest_port"`
}

type histogramRow struct {
	StartTime     int64   `parquet:"start_time,timestamp(microsecond)"`
	Label0        *string `parquet:"label0"`
	Label1        *string `parquet:"label1"`
	Label2        *string `parquet:"label2"`
	Label3        *string `parquet:"label3"`
	Label4        *string `parquet:"label4"`
	Label5        *string `parquet:"label5"`
	Label6        *string `parquet:"label6"`
	Label7        *string `parquet:"label7"`
	Label8        *string `parquet:"label8"`
	Label9        *string `parquet:"label9"`
	ACount        uint64  `parquet:"a_count"`
	AAAACount     uint64  `parquet:"aaaa_count"`
	OKCount       uint64  `parquet:"ok_count"`
	NXCount       uint64  `parquet:"nx_count"`
	V4ClientCount uint64  `parquet:"v4client_count"`
	V6ClientCount uint64  `parquet:"v6client_count"`
}

func main() {
	if len(os.Args) < 2 {
		fatalf("usage: e2e-test <run|populate-upstream|keygen|inject|mqtt-broker|parquet-check|mqtt-capture|mqtt-publish|summarize|supervise> [flags]")
	}

	var err error
	switch os.Args[1] {
	case "run":
		err = runE2E(os.Args[2:])
	case "populate-upstream":
		err = runPopulateUpstream(os.Args[2:])
	case "keygen":
		err = runKeygen(os.Args[2:])
	case "inject":
		err = runInject(os.Args[2:])
	case "mqtt-broker":
		err = runMQTTBroker(os.Args[2:])
	case "parquet-check":
		err = runParquetCheck(os.Args[2:])
	case "mqtt-capture":
		err = runMQTTCapture(os.Args[2:])
	case "mqtt-publish":
		err = runMQTTPublish(os.Args[2:])
	case "summarize":
		err = runSummarize(os.Args[2:])
	case "supervise":
		err = runSupervise(os.Args[2:])
	default:
		err = fmt.Errorf("unknown subcommand %q", os.Args[1])
	}
	if err != nil {
		fatalf("%v", err)
	}
}

func runSupervise(args []string) error {
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	if len(args) == 0 {
		return errors.New("usage: e2e-test supervise -- <command> [args...]")
	}

	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	configureSupervisedCommand(cmd)

	if err := cmd.Start(); err != nil {
		return err
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(signals)

	select {
	case sig := <-signals:
		terminateProcessGroup(cmd.Process.Pid, 5*time.Second)
		err := <-done
		if err != nil {
			return fmt.Errorf("supervised command exited after %s: %w", sig, err)
		}
		return nil
	case err := <-done:
		return err
	}
}

func terminateProcessGroup(pid int, grace time.Duration) {
	pgid, err := syscall.Getpgid(pid)
	if err != nil {
		return
	}
	_ = syscall.Kill(-pgid, syscall.SIGTERM)

	deadline := time.Now().Add(grace)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(-pgid, 0); err != nil {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	_ = syscall.Kill(-pgid, syscall.SIGKILL)
}

func runKeygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ExitOnError)
	dir := fs.String("dir", "", "output directory")
	edmKID := fs.String("edm-kid", "e2e-edm", "EDM JWS key ID")
	bridgeKID := fs.String("bridge-kid", "e2e-bridge", "downbound bridge JWS key ID")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *dir == "" {
		return errors.New("--dir is required")
	}
	if err := os.MkdirAll(*dir, 0o700); err != nil {
		return err
	}

	caCert, caKey, err := createCA(filepath.Join(*dir, "ca.crt"), filepath.Join(*dir, "ca.key"))
	if err != nil {
		return err
	}
	if err := createLeaf(filepath.Join(*dir, "server.crt"), filepath.Join(*dir, "server.key"), "dnstapir-e2e-mqtt", []string{"127.0.0.1", "localhost"}, caCert, caKey, true); err != nil {
		return err
	}
	if err := createLeaf(filepath.Join(*dir, "client.crt"), filepath.Join(*dir, "client.key"), "dnstapir-e2e-client", nil, caCert, caKey, false); err != nil {
		return err
	}
	if err := createEd25519JWK(filepath.Join(*dir, "edm-jws.json"), filepath.Join(*dir, "edm-jws-public.json"), *edmKID); err != nil {
		return err
	}
	if err := createEd25519JWK(filepath.Join(*dir, "bridge-jws.json"), filepath.Join(*dir, "bridge-jws-public.json"), *bridgeKID); err != nil {
		return err
	}
	return nil
}

func runMQTTBroker(args []string) error {
	fs := flag.NewFlagSet("mqtt-broker", flag.ExitOnError)
	addr := fs.String("addr", "127.0.0.1:28884", "MQTT listen address")
	if err := fs.Parse(args); err != nil {
		return err
	}

	server := mochimqtt.New(nil)
	if err := server.AddHook(new(auth.AllowHook), nil); err != nil {
		return err
	}
	if err := server.AddListener(listeners.NewTCP(listeners.Config{
		ID:      "tcp",
		Address: *addr,
	})); err != nil {
		return err
	}

	if err := server.Serve(); err != nil {
		return err
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(signals)

	sig := <-signals
	if err := server.Close(); err != nil {
		return fmt.Errorf("closing MQTT broker after %s: %w", sig, err)
	}
	return nil
}

func runInject(args []string) error {
	fs := flag.NewFlagSet("inject", flag.ExitOnError)
	fixturePath := fs.String("fixture", "", "fixture JSON path")
	target := fs.String("target", "tcp://127.0.0.1:53535", "EDM Frame Streams target")
	out := fs.String("out", "", "optional result JSON path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *fixturePath == "" {
		return errors.New("--fixture is required")
	}
	ff, err := readFixtureFile(*fixturePath)
	if err != nil {
		return err
	}
	addr, err := parseTarget(*target)
	if err != nil {
		return err
	}
	writer := dnstap.NewSocketWriter(addr, &dnstap.SocketWriterOptions{
		Timeout:       5 * time.Second,
		RetryInterval: time.Second,
		Dialer:        &net.Dialer{Timeout: 5 * time.Second},
	})
	defer writer.Close()

	res := injectResult{}
	for _, fx := range ff.Fixtures {
		frame, err := buildDNSTAPFrame(fx)
		if err != nil {
			return fmt.Errorf("%s: %w", fx.Name, err)
		}
		if _, err := writer.WriteFrame(frame); err != nil {
			return fmt.Errorf("%s: write dnstap frame: %w", fx.Name, err)
		}
		res.DNSTAPSent++
		res.Names = append(res.Names, normalizeDomain(fx.QName))
	}
	if *out != "" {
		return writeJSON(*out, res)
	}
	return json.NewEncoder(os.Stdout).Encode(res)
}

func runParquetCheck(args []string) error {
	fs := flag.NewFlagSet("parquet-check", flag.ExitOnError)
	fixturePath := fs.String("fixture", "", "fixture JSON path")
	dataDir := fs.String("data-dir", "", "EDM data dir")
	timeout := fs.Duration("timeout", 75*time.Second, "time to wait for parquet files")
	out := fs.String("out", "", "optional result JSON path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *fixturePath == "" || *dataDir == "" {
		return errors.New("--fixture and --data-dir are required")
	}
	ff, err := readFixtureFile(*fixturePath)
	if err != nil {
		return err
	}
	res, err := waitAndCheckParquet(*dataDir, ff, *timeout)
	if err != nil {
		return err
	}
	if *out != "" {
		return writeJSON(*out, res)
	}
	return json.NewEncoder(os.Stdout).Encode(res)
}

func runMQTTCapture(args []string) error {
	fs := flag.NewFlagSet("mqtt-capture", flag.ExitOnError)
	server := fs.String("server", "tls://127.0.0.1:18883", "MQTT server URL")
	topic := fs.String("topic", "", "MQTT topic to subscribe")
	ca := fs.String("ca", "", "CA cert")
	cert := fs.String("cert", "", "client cert")
	key := fs.String("key", "", "client key")
	verifyKey := fs.String("verify-key", "", "JWS validation key")
	out := fs.String("out", "", "verified payload output path")
	timeout := fs.Duration("timeout", 60*time.Second, "capture timeout")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *topic == "" || *out == "" {
		return errors.New("--topic and --out are required")
	}

	payloadCh := make(chan []byte, 1)
	cm, err := mqttConnect(*server, *ca, *cert, *key, mqttClientID("e2e-capture", *out), func(p paho.PublishReceived) {
		select {
		case payloadCh <- p.Packet.Payload:
		default:
		}
	})
	if err != nil {
		return err
	}
	defer cm.Disconnect(context.Background())

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	_, err = cm.Subscribe(ctx, &paho.Subscribe{
		Subscriptions: []paho.SubscribeOptions{{Topic: *topic, QoS: 0}},
	})
	cancel()
	if err != nil {
		return err
	}

	select {
	case signed := <-payloadCh:
		payload := signed
		if *verifyKey != "" {
			payload, err = verifyJWS(signed, *verifyKey)
			if err != nil {
				return err
			}
		}
		return os.WriteFile(*out, payload, 0o600)
	case <-time.After(*timeout):
		return fmt.Errorf("timed out waiting for MQTT topic %s", *topic)
	}
}

func runMQTTPublish(args []string) error {
	fs := flag.NewFlagSet("mqtt-publish", flag.ExitOnError)
	server := fs.String("server", "tls://127.0.0.1:18883", "MQTT server URL")
	topic := fs.String("topic", "", "MQTT topic")
	payload := fs.String("payload", "", "payload string")
	payloadFile := fs.String("payload-file", "", "payload file")
	ca := fs.String("ca", "", "CA cert")
	cert := fs.String("cert", "", "client cert")
	key := fs.String("key", "", "client key")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *topic == "" {
		return errors.New("--topic is required")
	}
	var body []byte
	var err error
	if *payloadFile != "" {
		body, err = os.ReadFile(*payloadFile)
		if err != nil {
			return err
		}
	} else {
		body = []byte(*payload)
	}

	cm, err := mqttConnect(*server, *ca, *cert, *key, mqttClientID("e2e-publish", *topic), nil)
	if err != nil {
		return err
	}
	defer cm.Disconnect(context.Background())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err = cm.Publish(ctx, &paho.Publish{Topic: *topic, Payload: body, QoS: 0})
	return err
}

func runSummarize(args []string) error {
	fs := flag.NewFlagSet("summarize", flag.ExitOnError)
	injectPath := fs.String("inject", "", "inject result JSON")
	upboundPath := fs.String("upbound", "", "verified EDM new_qname JSON")
	downboundPath := fs.String("downbound", "", "verified Core observation JSON")
	popPath := fs.String("pop", "", "POP artifact JSON")
	parquetPath := fs.String("parquet", "", "parquet result JSON")
	out := fs.String("out", "", "summary output JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *injectPath == "" || *upboundPath == "" || *downboundPath == "" || *popPath == "" || *parquetPath == "" || *out == "" {
		return errors.New("--inject, --upbound, --downbound, --pop, --parquet, and --out are required")
	}
	var inj injectResult
	if err := readJSON(*injectPath, &inj); err != nil {
		return err
	}
	var pop popArtifactSummary
	if err := readJSON(*popPath, &pop); err != nil {
		return err
	}
	var pq parquetResult
	if err := readJSON(*parquetPath, &pq); err != nil {
		return err
	}
	upbound, err := os.ReadFile(*upboundPath)
	if err != nil {
		return err
	}
	downbound, err := os.ReadFile(*downboundPath)
	if err != nil {
		return err
	}
	summary := harnessSummary{
		DNSTAPSent:           inj.DNSTAPSent,
		MQTTNewQNameSeen:     1,
		CoreObservationsSeen: 1,
		RPZRecords:           pop.RPZRecords,
		SessionParquetRows:   pq.SessionParquetRows,
		HistogramParquetRows: pq.HistogramParquetRows,
		UpboundNewQName:      upbound,
		DownboundObservation: downbound,
	}
	return writeJSON(*out, summary)
}

func readFixtureFile(path string) (fixtureFile, error) {
	var ff fixtureFile
	body, err := os.ReadFile(path)
	if err != nil {
		return ff, err
	}
	if err := json.Unmarshal(body, &ff); err != nil {
		return ff, err
	}
	if ff.FixtureVersion != 1 {
		return ff, fmt.Errorf("unsupported fixture_version %d", ff.FixtureVersion)
	}
	return ff, nil
}

func buildDNSTAPFrame(fx fixture) ([]byte, error) {
	dnsWire, err := buildDNSResponse(fx)
	if err != nil {
		return nil, err
	}
	src, err := netipFromString(fx.ClientIP)
	if err != nil {
		return nil, err
	}
	dst, err := netipFromString(fx.ResolverIP)
	if err != nil {
		return nil, err
	}
	at, err := time.Parse(time.RFC3339, fx.ResponseTime)
	if err != nil {
		return nil, err
	}
	fam := dnstap.SocketFamily_INET
	srcBytes := src.AsSlice()
	dstBytes := dst.AsSlice()
	if src.Is6() && !src.Is4In6() {
		fam = dnstap.SocketFamily_INET6
	}
	protoUDP := dnstap.SocketProtocol_UDP
	msgType := dnstap.Message_CLIENT_RESPONSE
	dtType := dnstap.Dnstap_MESSAGE
	srcPort := uint32(fx.ClientPort)
	dstPort := uint32(fx.ResolverPort)
	sec := uint64(at.Unix())
	nsec := uint32(at.Nanosecond())
	dt := dnstap.Dnstap{
		Identity: []byte(dnstapIdentity),
		Type:     &dtType,
		Message: &dnstap.Message{
			Type:             &msgType,
			SocketFamily:     &fam,
			SocketProtocol:   &protoUDP,
			QueryAddress:     srcBytes,
			ResponseAddress:  dstBytes,
			QueryPort:        &srcPort,
			ResponsePort:     &dstPort,
			ResponseTimeSec:  &sec,
			ResponseTimeNsec: &nsec,
			ResponseMessage:  dnsWire,
		},
	}
	return proto.Marshal(&dt)
}

type netipAddr struct {
	ip net.IP
}

func netipFromString(s string) (netipAddr, error) {
	ip := net.ParseIP(s)
	if ip == nil {
		return netipAddr{}, fmt.Errorf("invalid IP %q", s)
	}
	return netipAddr{ip: ip}, nil
}

func (a netipAddr) Is6() bool {
	return a.ip.To4() == nil
}

func (a netipAddr) Is4In6() bool {
	return false
}

func (a netipAddr) AsSlice() []byte {
	if ip4 := a.ip.To4(); ip4 != nil {
		return ip4
	}
	return a.ip.To16()
}

func buildDNSResponse(fx fixture) ([]byte, error) {
	m := new(dns.Msg)
	m.SetQuestion(normalizeDomain(fx.QName), fx.QType)
	m.Question[0].Qclass = fx.QClass
	m.Response = true
	m.Authoritative = true
	m.RecursionAvailable = true
	m.Rcode = fx.RCode
	for _, ans := range fx.Answers {
		rr, err := buildRR(fx, ans)
		if err != nil {
			return nil, err
		}
		m.Answer = append(m.Answer, rr)
	}
	return m.Pack()
}

func buildRR(fx fixture, ans dnsAnswer) (dns.RR, error) {
	name := ans.Name
	if name == "" {
		name = fx.QName
	}
	ttl := ans.TTL
	if ttl == 0 {
		ttl = 60
	}
	h := dns.RR_Header{Name: normalizeDomain(name), Class: dns.ClassINET, Ttl: ttl}
	switch strings.ToUpper(ans.Type) {
	case "A":
		ip := net.ParseIP(ans.Value).To4()
		if ip == nil {
			return nil, fmt.Errorf("invalid A record IP %q", ans.Value)
		}
		h.Rrtype = dns.TypeA
		return &dns.A{Hdr: h, A: ip}, nil
	case "AAAA":
		ip := net.ParseIP(ans.Value)
		if ip == nil || ip.To4() != nil {
			return nil, fmt.Errorf("invalid AAAA record IP %q", ans.Value)
		}
		h.Rrtype = dns.TypeAAAA
		return &dns.AAAA{Hdr: h, AAAA: ip}, nil
	case "CNAME":
		h.Rrtype = dns.TypeCNAME
		return &dns.CNAME{Hdr: h, Target: normalizeDomain(ans.Value)}, nil
	case "TXT":
		h.Rrtype = dns.TypeTXT
		return &dns.TXT{Hdr: h, Txt: []string{ans.Value}}, nil
	default:
		return nil, fmt.Errorf("unsupported answer type %q", ans.Type)
	}
}

func parseTarget(target string) (net.Addr, error) {
	u, err := url.Parse(target)
	if err != nil {
		return nil, err
	}
	switch strings.ToLower(u.Scheme) {
	case "tcp":
		return net.ResolveTCPAddr("tcp", u.Host)
	case "unix":
		path := u.Path
		if u.Host != "" && path == "" {
			path = u.Host
		}
		return net.ResolveUnixAddr("unix", path)
	default:
		return nil, fmt.Errorf("unsupported target scheme %q", u.Scheme)
	}
}

func waitAndCheckParquet(dataDir string, ff fixtureFile, timeout time.Duration) (parquetResult, error) {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		res, err := checkParquet(dataDir, ff)
		if err == nil {
			return res, nil
		}
		lastErr = err
		if time.Now().After(deadline) {
			return parquetResult{}, lastErr
		}
		time.Sleep(time.Second)
	}
}

func checkParquet(dataDir string, ff fixtureFile) (parquetResult, error) {
	res := parquetResult{}
	var err error
	res.SessionFiles, err = parquetFiles(filepath.Join(dataDir, "parquet", "sessions"))
	if err != nil {
		return res, err
	}
	res.HistogramFiles, err = parquetFiles(filepath.Join(dataDir, "parquet", "histograms", "outbox"))
	if err != nil {
		return res, err
	}
	if len(res.SessionFiles) == 0 {
		return res, errors.New("no session parquet files found")
	}
	if len(res.HistogramFiles) == 0 {
		return res, errors.New("no histogram parquet files found")
	}

	sessionRows := make([]sessionRow, 0)
	for _, path := range res.SessionFiles {
		rows, err := parquet.ReadFile[sessionRow](path)
		if err != nil {
			return res, fmt.Errorf("read session parquet %s: %w", path, err)
		}
		sessionRows = append(sessionRows, rows...)
	}
	histRows := make([]histogramRow, 0)
	for _, path := range res.HistogramFiles {
		rows, err := parquet.ReadFile[histogramRow](path)
		if err != nil {
			return res, fmt.Errorf("read histogram parquet %s: %w", path, err)
		}
		histRows = append(histRows, rows...)
	}
	res.SessionParquetRows = len(sessionRows)
	res.HistogramParquetRows = len(histRows)

	for _, fx := range ff.Fixtures {
		qname := normalizeDomain(fx.QName)
		if fx.Expected.Session {
			if !sessionContains(sessionRows, qname) {
				return res, fmt.Errorf("session parquet missing %s", qname)
			}
			res.SessionMatched = appendUnique(res.SessionMatched, qname)
		}
		if fx.Expected.Histogram {
			if !histogramContains(histRows, qname, fx.QType, fx.RCode) {
				return res, fmt.Errorf("histogram parquet missing %s", qname)
			}
			res.HistogramMatched = appendUnique(res.HistogramMatched, qname)
		} else if histogramContainsDomain(histRows, qname) {
			return res, fmt.Errorf("histogram parquet unexpectedly contains %s", qname)
		}
	}
	sort.Strings(res.SessionMatched)
	sort.Strings(res.HistogramMatched)
	return res, nil
}

func parquetFiles(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if strings.HasSuffix(name, ".parquet") {
			files = append(files, filepath.Join(dir, name))
		}
	}
	sort.Strings(files)
	return files, nil
}

func sessionContains(rows []sessionRow, qname string) bool {
	for _, row := range rows {
		if row.ServerID != nil && *row.ServerID != dnstapIdentity {
			continue
		}
		if labelsToDomain(row.Label0, row.Label1, row.Label2, row.Label3, row.Label4, row.Label5, row.Label6, row.Label7, row.Label8, row.Label9) == qname {
			return true
		}
	}
	return false
}

func histogramContains(rows []histogramRow, qname string, qtype uint16, rcode int) bool {
	for _, row := range rows {
		if labelsToDomain(row.Label0, row.Label1, row.Label2, row.Label3, row.Label4, row.Label5, row.Label6, row.Label7, row.Label8, row.Label9) != qname {
			continue
		}
		if qtype == dns.TypeA && row.ACount == 0 {
			continue
		}
		if rcode == dns.RcodeSuccess && row.OKCount == 0 {
			continue
		}
		if row.V4ClientCount == 0 && row.V6ClientCount == 0 {
			continue
		}
		return true
	}
	return false
}

func histogramContainsDomain(rows []histogramRow, qname string) bool {
	for _, row := range rows {
		if labelsToDomain(row.Label0, row.Label1, row.Label2, row.Label3, row.Label4, row.Label5, row.Label6, row.Label7, row.Label8, row.Label9) == qname {
			return true
		}
	}
	return false
}

func labelsToDomain(labels ...*string) string {
	var parts []string
	for _, label := range labels {
		if label != nil && *label != "" {
			parts = append(parts, *label)
		}
	}
	for i, j := 0, len(parts)-1; i < j; i, j = i+1, j-1 {
		parts[i], parts[j] = parts[j], parts[i]
	}
	if len(parts) == 0 {
		return "."
	}
	return normalizeDomain(strings.Join(parts, "."))
}

func mqttConnect(server, caPath, certPath, keyPath, clientID string, onPublish func(paho.PublishReceived)) (*autopaho.ConnectionManager, error) {
	u, err := url.Parse(server)
	if err != nil {
		return nil, err
	}
	cfg := autopaho.ClientConfig{
		ServerUrls:                    []*url.URL{u},
		KeepAlive:                     20,
		CleanStartOnInitialConnection: true,
		ClientConfig: paho.ClientConfig{
			ClientID: clientID,
		},
		OnConnectError: func(err error) {
			fmt.Fprintf(os.Stderr, "mqtt connect error: %v\n", err)
		},
	}
	if onPublish != nil {
		cfg.ClientConfig.OnPublishReceived = []func(paho.PublishReceived) (bool, error){
			func(p paho.PublishReceived) (bool, error) {
				onPublish(p)
				return true, nil
			},
		}
	}
	if u.Scheme == "tls" || u.Scheme == "mqtts" {
		tlsCfg := &tls.Config{MinVersion: tls.VersionTLS13}
		if caPath != "" {
			caPEM, err := os.ReadFile(caPath)
			if err != nil {
				return nil, err
			}
			pool := x509.NewCertPool()
			if !pool.AppendCertsFromPEM(caPEM) {
				return nil, errors.New("failed to parse CA cert")
			}
			tlsCfg.RootCAs = pool
		}
		if certPath != "" || keyPath != "" {
			cert, err := tls.LoadX509KeyPair(certPath, keyPath)
			if err != nil {
				return nil, err
			}
			tlsCfg.Certificates = []tls.Certificate{cert}
		}
		cfg.TlsCfg = tlsCfg
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cm, err := autopaho.NewConnection(context.Background(), cfg)
	if err != nil {
		return nil, err
	}
	if err := cm.AwaitConnection(ctx); err != nil {
		return nil, err
	}
	return cm, nil
}

func mqttClientID(prefix, seed string) string {
	var b strings.Builder
	for _, r := range seed {
		switch {
		case r >= 'a' && r <= 'z':
			b.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r)
		case r >= '0' && r <= '9':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	id := prefix + "-" + strings.Trim(b.String(), "-")
	if len(id) > 64 {
		return id[:64]
	}
	return id
}

func verifyJWS(signed []byte, keyPath string) ([]byte, error) {
	key, err := parseJWK(keyPath)
	if err != nil {
		return nil, err
	}
	return jws.Verify(signed, jws.WithJSON(), jws.WithKey(key.Algorithm(), key))
}

func parseJWK(path string) (jwk.Key, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	key, err := jwk.ParseKey(body)
	if err != nil {
		return nil, err
	}
	if private, _ := jwk.IsPrivateKey(key); private {
		pub, err := key.PublicKey()
		if err != nil {
			return nil, err
		}
		key = pub
	}
	return key, nil
}

func createCA(certPath, keyPath string) (*x509.Certificate, *ecdsa.PrivateKey, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial(),
		Subject:               pkix.Name{CommonName: "DNS Tapir E2E CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	if err := writeCertPEM(certPath, der); err != nil {
		return nil, nil, err
	}
	if err := writeECKeyPEM(keyPath, key); err != nil {
		return nil, nil, err
	}
	cert, err := x509.ParseCertificate(der)
	return cert, key, err
}

func createLeaf(certPath, keyPath, cn string, hosts []string, caCert *x509.Certificate, caKey *ecdsa.PrivateKey, server bool) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	tmpl := &x509.Certificate{
		SerialNumber: serial(),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
	}
	if server {
		tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
		for _, h := range hosts {
			if ip := net.ParseIP(h); ip != nil {
				tmpl.IPAddresses = append(tmpl.IPAddresses, ip)
			} else {
				tmpl.DNSNames = append(tmpl.DNSNames, h)
			}
		}
	} else {
		tmpl.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		return err
	}
	if err := writeCertPEM(certPath, der); err != nil {
		return err
	}
	return writeECKeyPEM(keyPath, key)
}

func createEd25519JWK(privatePath, publicPath, kid string) error {
	pubRaw, privRaw, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	priv, err := jwk.FromRaw(privRaw)
	if err != nil {
		return err
	}
	if err := setJWKMeta(priv, kid); err != nil {
		return err
	}
	pub, err := jwk.FromRaw(pubRaw)
	if err != nil {
		return err
	}
	if err := setJWKMeta(pub, kid); err != nil {
		return err
	}
	privBody, err := json.MarshalIndent(priv, "", "  ")
	if err != nil {
		return err
	}
	pubBody, err := json.MarshalIndent(pub, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(privatePath, privBody, 0o600); err != nil {
		return err
	}
	return os.WriteFile(publicPath, pubBody, 0o600)
}

func setJWKMeta(key jwk.Key, kid string) error {
	if err := key.Set(jwk.KeyIDKey, kid); err != nil {
		return err
	}
	if err := key.Set(jwk.AlgorithmKey, jwa.EdDSA); err != nil {
		return err
	}
	return key.Set("iss", "dnstapir-e2e")
}

func writeCertPEM(path string, der []byte) error {
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
}

func writeECKeyPEM(path string, key *ecdsa.PrivateKey) error {
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	return os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: der}), 0o600)
}

func serial() *big.Int {
	max := new(big.Int).Lsh(big.NewInt(1), 128)
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		panic(err)
	}
	return n
}

func normalizeDomain(name string) string {
	return dns.Fqdn(strings.ToLower(strings.TrimSpace(name)))
}

func appendUnique(values []string, v string) []string {
	for _, existing := range values {
		if existing == v {
			return values
		}
	}
	return append(values, v)
}

func writeJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	body, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	body = append(body, '\n')
	return os.WriteFile(path, body, 0o600)
}

func readJSON(path string, v any) error {
	body, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, v)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

var _ = base64.RawURLEncoding
