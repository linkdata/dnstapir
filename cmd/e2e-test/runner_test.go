package main

import (
	"os"
	"path/filepath"
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
