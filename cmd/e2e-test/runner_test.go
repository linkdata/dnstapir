package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFindRepoRootAbove(t *testing.T) {
	root := t.TempDir()
	fixtureDir := filepath.Join(root, "fixtures")
	cmdDir := filepath.Join(root, "cmd", "e2e-test")
	binDir := filepath.Join(root, ".e2e-work", "bin")

	for _, dir := range []string{fixtureDir, cmdDir, binDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module dnstapir-e2e\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(fixtureDir, "dnstap-fixtures.json"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cmdDir, "main.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	for _, start := range []string{root, fixtureDir, cmdDir, binDir} {
		got, ok := findRepoRootAbove(start)
		if !ok {
			t.Fatalf("findRepoRootAbove(%q) did not find a root", start)
		}
		if got != root {
			t.Fatalf("findRepoRootAbove(%q) = %q, want %q", start, got, root)
		}
	}
}

func TestPopulateUpstreamClonesRequiredRepos(t *testing.T) {
	root := t.TempDir()
	logPath := installFakeGit(t)

	if err := runPopulateUpstream([]string{"--root", root}); err != nil {
		t.Fatal(err)
	}

	assertRequiredRepoClones(t, root, logPath)
}

func TestEnsureUpstreamReposPopulatesMissingDefaults(t *testing.T) {
	root := t.TempDir()
	logPath := installFakeGit(t)
	r := &e2eRunner{
		paths: e2ePaths{
			root:     root,
			upstream: filepath.Join(root, "upstream"),
		},
	}

	if err := r.ensureUpstreamRepos(); err != nil {
		t.Fatal(err)
	}

	assertRequiredRepoClones(t, root, logPath)
}

func assertRequiredRepoClones(t *testing.T, root string, logPath string) {
	t.Helper()

	logBody, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	log := string(logBody)
	for _, name := range requiredUpstreamRepoNames {
		repo, ok := upstreamRepoByName(name)
		if !ok {
			t.Fatalf("test references unknown upstream repo %s", name)
		}
		want := "clone " + repo.url + " " + filepath.Join(root, "upstream", name)
		if !strings.Contains(log, want) {
			t.Fatalf("fake git log missing %q:\n%s", want, log)
		}
		if !dirExists(filepath.Join(root, "upstream", name)) {
			t.Fatalf("missing cloned directory for %s", name)
		}
	}
	if got, want := strings.Count(strings.TrimSpace(log), "\n")+1, len(requiredUpstreamRepoNames); got != want {
		t.Fatalf("clone count = %d, want %d; log:\n%s", got, want, log)
	}
}

func TestEnsureUpstreamReposRejectsMissingExplicitOverrides(t *testing.T) {
	root := t.TempDir()
	r := &e2eRunner{
		paths: e2ePaths{
			root:     root,
			upstream: filepath.Join(root, "upstream"),
		},
		edmRepo: filepath.Join(root, "missing-edm"),
	}

	err := r.ensureUpstreamRepos()
	if err == nil || !strings.Contains(err.Error(), "missing EDM checkout") {
		t.Fatalf("ensureUpstreamRepos() error = %v, want missing EDM checkout", err)
	}
}

func installFakeGit(t *testing.T) string {
	t.Helper()

	binDir := filepath.Join(t.TempDir(), "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	logPath := filepath.Join(t.TempDir(), "git.log")
	gitPath := filepath.Join(binDir, "git")
	script := `#!/bin/sh
echo "$@" >> "$GIT_LOG"
if [ "$1" != "clone" ]; then
	exit 2
fi
mkdir -p "$3"
`
	if err := os.WriteFile(gitPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_LOG", logPath)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return logPath
}
