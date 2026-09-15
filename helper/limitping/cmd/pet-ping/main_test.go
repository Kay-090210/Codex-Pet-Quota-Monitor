package main

import (
	"errors"
	"os"
	"testing"
)

func TestErrorCategoriesNeverExposeRawText(t *testing.T) {
	for _, tc := range []struct{ message, category string }{
		{"codex interactive authentication failed; private text", "authentication"},
		{"codex interactive turn result was not observed within 90s", "timeout"},
		{"codex interactive failed to start: private path", "cli_start"},
		{"codex turn failed: private response", "session_failed"},
	} {
		if got := classify(errors.New(tc.message)); got != tc.category {
			t.Fatalf("category = %q", got)
		}
	}
}

func TestDryRunDoesNotLaunchCLI(t *testing.T) {
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Chdir(cwd) }()
	t.Setenv("CODEX_HOME", "")
	t.Setenv("LIMITPING_CODEX_HOME", "")
	// No executable on PATH: a real CLI launch would fail.
	t.Setenv("PATH", "")
	home, work := t.TempDir(), t.TempDir()
	r, code := run([]string{"--home", home, "--workdir", work, "--dry-run"})
	if code != 0 || r.Completed || !r.DryRun || r.Category != "dry_run" {
		t.Fatalf("result=%+v code=%d", r, code)
	}
}

func TestInvalidPathsDoNotLaunchCLI(t *testing.T) {
	r, code := run([]string{"--home", "relative", "--workdir", "relative"})
	if code != 1 || r.Completed || r.Category != "invalid_configuration" {
		t.Fatalf("result=%+v code=%d", r, code)
	}
}
