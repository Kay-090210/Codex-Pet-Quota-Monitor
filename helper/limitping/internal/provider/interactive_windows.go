//go:build windows

package provider

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"

	"github.com/UserExistsError/conpty"
	"golang.org/x/sys/windows"
)

type windowsInteractivePTY struct {
	conpty    *conpty.ConPty
	closeOnce sync.Once
	closeErr  error
}

func startPlatformPTY(ctx context.Context, name string, args ...string) (interactivePTY, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	commandLine, err := windowsPTYCommandLine(name, args)
	if err != nil {
		return nil, err
	}
	workDir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	codexHome := resolveLimitPingCodexHome(os.Environ(), os.Executable)

	cpty, err := conpty.Start(commandLine,
		conpty.ConPtyWorkDir(workDir),
		conpty.ConPtyEnv(windowsPTYEnv(os.Environ(), codexHome)),
	)
	if err != nil {
		return nil, err
	}
	return &windowsInteractivePTY{conpty: cpty}, nil
}

// Codex Desktop launches tools with TERM=dumb in some environments. That is
// appropriate for plain redirected output, but a child attached to ConPTY is
// interactive; recent Codex CLIs refuse to start their TUI when it is kept.
func windowsPTYEnv(env []string, codexHome string) []string {
	out := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if key, value, ok := strings.Cut(entry, "="); ok {
			if strings.EqualFold(key, "TERM") && strings.EqualFold(value, "dumb") {
				continue
			}
			// A ping must be an independent minimal turn. Reusing the parent
			// Desktop task would pull in its context and consume much more quota.
			if strings.EqualFold(key, "CODEX_SESSION_ID") || strings.EqualFold(key, "CODEX_THREAD_ID") {
				continue
			}
			if codexHome != "" && strings.EqualFold(key, "CODEX_HOME") {
				continue
			}
		}
		out = append(out, entry)
	}
	if codexHome != "" {
		out = append(out, "CODEX_HOME="+codexHome)
	}
	return out
}

// resolveLimitPingCodexHome lets the installed watcher use a deliberately
// minimal Codex profile without changing the user's normal Desktop/CLI profile.
// LIMITPING_CODEX_HOME is an explicit override; otherwise a codex-home folder
// beside limitping.exe is selected when present.
func resolveLimitPingCodexHome(env []string, executable func() (string, error)) string {
	for _, entry := range env {
		key, value, ok := strings.Cut(entry, "=")
		if ok && strings.EqualFold(key, "LIMITPING_CODEX_HOME") {
			return strings.TrimSpace(value)
		}
	}
	exe, err := executable()
	if err != nil || exe == "" {
		return ""
	}
	candidate := filepath.Join(filepath.Dir(exe), "codex-home")
	info, err := os.Stat(candidate)
	if err != nil || !info.IsDir() {
		return ""
	}
	return candidate
}

// windowsPTYCommandLine resolves the executable before handing it to
// CreateProcess. npm-installed CLIs are .cmd launchers on Windows, and those
// must run through cmd.exe rather than CreateProcess directly.
func windowsPTYCommandLine(name string, args []string) (string, error) {
	resolved, err := exec.LookPath(name)
	if err != nil {
		return "", err
	}
	argv := append([]string{resolved}, args...)
	ext := strings.ToLower(filepath.Ext(resolved))
	if ext != ".cmd" && ext != ".bat" {
		return windows.ComposeCommandLine(argv), nil
	}

	comspec := strings.TrimSpace(os.Getenv("ComSpec"))
	if comspec == "" {
		comspec = "cmd.exe"
	}
	comspec, err = exec.LookPath(comspec)
	if err != nil {
		return "", err
	}
	inner := windows.ComposeCommandLine(argv)
	return windows.ComposeCommandLine([]string{comspec, "/d", "/s", "/c", inner}), nil
}

func (p *windowsInteractivePTY) Read(b []byte) (int, error) {
	n, err := p.conpty.Read(b)
	if errors.Is(err, windows.ERROR_BROKEN_PIPE) || errors.Is(err, windows.ERROR_NO_DATA) || errors.Is(err, windows.ERROR_INVALID_HANDLE) {
		return n, io.EOF
	}
	return n, err
}
func (p *windowsInteractivePTY) Write(b []byte) (int, error) { return p.conpty.Write(b) }

func (p *windowsInteractivePTY) Close() error {
	p.closeOnce.Do(func() { p.closeErr = p.conpty.Close() })
	return p.closeErr
}

func (p *windowsInteractivePTY) Kill() error { return p.Close() }

func (p *windowsInteractivePTY) Wait() error {
	exitCode, err := p.conpty.Wait(context.Background())
	if err != nil {
		return err
	}
	if exitCode != 0 {
		return fmt.Errorf("process exited with code %d", exitCode)
	}
	return nil
}
