//go:build windows

package provider

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestNewestDesktopCodexPrefersCurrentRuntime(t *testing.T) {
	bin := t.TempDir()
	stable := filepath.Join(bin, "codex.exe")
	current := filepath.Join(bin, "runtime-hash", "codex.exe")
	if err := os.MkdirAll(filepath.Dir(current), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{stable, current} {
		if err := os.WriteFile(path, []byte("fixture"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(stable, old, old); err != nil {
		t.Fatal(err)
	}

	if got := newestDesktopCodex(bin); got != current {
		t.Fatalf("newestDesktopCodex = %q, want %q", got, current)
	}
}
