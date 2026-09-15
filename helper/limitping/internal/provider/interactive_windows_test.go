//go:build windows

package provider

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestWindowsPTYStartsNativeCommand(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	p, err := startInteractivePTY(ctx, "cmd.exe", "/d", "/c", "echo", "CONPTY_READY")
	if err != nil {
		t.Fatalf("startInteractivePTY: %v", err)
	}
	defer p.Close()

	out := collectWindowsPTY(t, ctx, p)
	if !strings.Contains(string(out), "CONPTY_READY") {
		t.Fatalf("output = %q, want CONPTY_READY", out)
	}
}

func TestWindowsPTYStartsCmdShim(t *testing.T) {
	dir := t.TempDir()
	shim := filepath.Join(dir, "limitping-pty-probe.cmd")
	if err := os.WriteFile(shim, []byte("@echo SHIM_READY\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	p, err := startInteractivePTY(ctx, "limitping-pty-probe")
	if err != nil {
		t.Fatalf("startInteractivePTY: %v", err)
	}
	defer p.Close()

	out := collectWindowsPTY(t, ctx, p)
	if !strings.Contains(string(out), "SHIM_READY") {
		t.Fatalf("output = %q, want SHIM_READY", out)
	}
}

func TestWindowsPTYEnvSanitizesHostOnlyValues(t *testing.T) {
	got := windowsPTYEnv([]string{
		"Path=C:\\bin",
		"TERM=dumb",
		"TERM_PROGRAM=codex",
		"CODEX_SESSION_ID=session",
		"CODEX_THREAD_ID=thread",
		"CODEX_HOME=C:\\Users\\fixture\\.codex",
		"OTHER=1",
	}, "E:\\Tools\\limitping\\codex-home")
	want := []string{"Path=C:\\bin", "TERM_PROGRAM=codex", "OTHER=1", "CODEX_HOME=E:\\Tools\\limitping\\codex-home"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("windowsPTYEnv = %#v, want %#v", got, want)
	}
	got = windowsPTYEnv([]string{"TERM=xterm-256color"}, "")
	if len(got) != 1 || got[0] != "TERM=xterm-256color" {
		t.Fatalf("windowsPTYEnv removed a supported TERM: %#v", got)
	}
}

func TestResolveLimitPingCodexHome(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "limitping.exe")
	if err := os.WriteFile(exe, nil, 0o644); err != nil {
		t.Fatal(err)
	}

	if got := resolveLimitPingCodexHome([]string{"LIMITPING_CODEX_HOME=E:\\isolated"}, func() (string, error) {
		return exe, nil
	}); got != "E:\\isolated" {
		t.Fatalf("explicit home = %q, want E:\\isolated", got)
	}

	if got := resolveLimitPingCodexHome(nil, func() (string, error) { return exe, nil }); got != "" {
		t.Fatalf("missing sibling home = %q, want empty", got)
	}
	want := filepath.Join(dir, "codex-home")
	if err := os.Mkdir(want, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := resolveLimitPingCodexHome(nil, func() (string, error) { return exe, nil }); got != want {
		t.Fatalf("sibling home = %q, want %q", got, want)
	}
}

func collectWindowsPTY(t *testing.T, ctx context.Context, p interactivePTY) []byte {
	t.Helper()
	type readResult struct {
		data []byte
		err  error
	}
	readDone := make(chan readResult, 1)
	waitDone := make(chan error, 1)
	go func() {
		data, err := io.ReadAll(p)
		readDone <- readResult{data: data, err: err}
	}()
	go func() { waitDone <- p.Wait() }()

	select {
	case err := <-waitDone:
		if err != nil {
			t.Fatalf("waiting for ConPTY child: %v", err)
		}
	case <-ctx.Done():
		_ = p.Kill()
		t.Fatalf("waiting for ConPTY child: %v", ctx.Err())
	}

	// ConPTY keeps its output pipe open until the pseudo console itself closes,
	// even after the child process exits.
	_ = p.Close()
	select {
	case result := <-readDone:
		if result.err != nil {
			t.Fatalf("reading ConPTY output: %v", result.err)
		}
		return result.data
	case <-ctx.Done():
		t.Fatalf("reading ConPTY output: %v", ctx.Err())
		return nil
	}
}
