package activity

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// sandbox points config.Dir() at a temp dir so markers don't touch the real home.
func sandbox(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
}

func TestMarkActiveClear(t *testing.T) {
	sandbox(t)

	if _, active, err := Active("claude"); err != nil || active {
		t.Fatalf("fresh provider: active=%v err=%v, want false/nil", active, err)
	}

	if err := Mark("claude", "sess1", "UserPromptSubmit"); err != nil {
		t.Fatalf("Mark: %v", err)
	}
	desc, active, err := Active("claude")
	if err != nil || !active {
		t.Fatalf("after Mark: active=%v err=%v, want true/nil", active, err)
	}
	if desc == "" {
		t.Fatal("expected a non-empty description")
	}

	if err := Clear("claude", "sess1"); err != nil {
		t.Fatalf("Clear: %v", err)
	}
	if _, active, _ := Active("claude"); active {
		t.Fatal("after Clear: want inactive")
	}
}

func TestClearMissingIsNoError(t *testing.T) {
	sandbox(t)
	if err := Clear("codex", "nope"); err != nil {
		t.Fatalf("Clear missing: %v", err)
	}
}

func TestConcurrentSessionsIndependent(t *testing.T) {
	sandbox(t)
	if err := Mark("claude", "a", "PreToolUse"); err != nil {
		t.Fatal(err)
	}
	if err := Mark("claude", "b", "PreToolUse"); err != nil {
		t.Fatal(err)
	}
	// One session ending must not mark the other idle.
	if err := Clear("claude", "a"); err != nil {
		t.Fatal(err)
	}
	if _, active, _ := Active("claude"); !active {
		t.Fatal("session b still running; want active")
	}
}

func TestStaleMarkerPruned(t *testing.T) {
	sandbox(t)
	if err := Mark("claude", "old", "PreToolUse"); err != nil {
		t.Fatal(err)
	}

	// Backdate the marker beyond the TTL.
	dir, err := providerDir("claude")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "old.json")
	stale := marker{Event: "PreToolUse", UpdatedAt: time.Now().Add(-activityTTL - time.Minute)}
	writeMarker(t, path, stale)

	if _, active, _ := Active("claude"); active {
		t.Fatal("stale marker should not count as active")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatal("stale marker should have been pruned")
	}
}

func TestStopEventMarkerIgnored(t *testing.T) {
	sandbox(t)
	// A marker whose recorded event is a stop event must not count as active
	// (defensive: Clear normally removes it first).
	dir, err := providerDir("claude")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeMarker(t, filepath.Join(dir, "x.json"), marker{Event: "Stop", UpdatedAt: time.Now()})
	if _, active, _ := Active("claude"); active {
		t.Fatal("stop-event marker should not count as active")
	}
}

func TestEnabledSentinel(t *testing.T) {
	sandbox(t)
	if Enabled("claude") {
		t.Fatal("not enabled before SetEnabled")
	}
	if err := SetEnabled("claude", true); err != nil {
		t.Fatal(err)
	}
	if !Enabled("claude") {
		t.Fatal("should be enabled after SetEnabled(true)")
	}
	if err := SetEnabled("claude", false); err != nil {
		t.Fatal(err)
	}
	if Enabled("claude") {
		t.Fatal("should be disabled after SetEnabled(false)")
	}
	// Idempotent removal.
	if err := SetEnabled("claude", false); err != nil {
		t.Fatalf("SetEnabled(false) when absent: %v", err)
	}
}

func TestSanitize(t *testing.T) {
	cases := map[string]string{
		"abc-123_DEF": "abc-123_DEF",
		"../etc":      "etc",
		"a/b/c":       "c",
		"":            "default",
		"!@#$":        "default",
	}
	for in, want := range cases {
		if got := sanitize(in); got != want {
			t.Errorf("sanitize(%q) = %q, want %q", in, got, want)
		}
	}
}

func writeMarker(t *testing.T, path string, m marker) {
	t.Helper()
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}
