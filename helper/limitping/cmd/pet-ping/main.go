// pet-ping adapts limitping's existing single-turn provider without its scheduler.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/wavever/CCLimitPing/internal/config"
	"github.com/wavever/CCLimitPing/internal/provider"
)

type result struct {
	Completed  bool   `json:"completed"`
	DryRun     bool   `json:"dryRun"`
	Category   string `json:"category"`
	DurationMs int64  `json:"durationMs"`
}

func classify(err error) string {
	s := strings.ToLower(err.Error())
	switch {
	case strings.Contains(s, "authentication"), strings.Contains(s, "not logged in"):
		return "authentication"
	case strings.Contains(s, "not observed within"), strings.Contains(s, "cancelled"):
		return "timeout"
	case strings.Contains(s, "failed to start"):
		return "cli_start"
	default:
		return "session_failed"
	}
}

func run(args []string) (result, int) {
	start := time.Now()
	r := result{Category: "invalid_configuration"}
	flags := flag.NewFlagSet("pet-ping", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	home := flags.String("home", "", "Existing absolute Codex profile directory")
	workdir := flags.String("workdir", "", "Existing absolute trusted working directory")
	model := flags.String("model", "gpt-5.6-luna", "Codex model")
	dry := flags.Bool("dry-run", false, "Build command without sending a message")
	waitForParent := flags.Bool("wait-for-parent", false, "Wait for parent process containment before starting")
	if flags.Parse(args) != nil || flags.NArg() != 0 {
		return r, 1
	}
	if *waitForParent {
		// The parent sends go only after assigning this process to its job object.
		line, err := bufio.NewReader(io.LimitReader(os.Stdin, 16)).ReadString('\n')
		if err != nil || strings.TrimSpace(line) != "go" {
			return r, 1
		}
	}
	for _, dir := range []string{*home, *workdir} {
		info, err := os.Stat(dir)
		if !filepath.IsAbs(dir) || err != nil || !info.IsDir() {
			return r, 1
		}
	}
	if *model == "" || strings.ContainsAny(*model, "\r\n") {
		return r, 1
	}
	if os.Setenv("LIMITPING_CODEX_HOME", *home) != nil || os.Setenv("CODEX_HOME", *home) != nil || os.Chdir(*workdir) != nil {
		return r, 1
	}
	r.DryRun = *dry
	_, err := provider.NewCodex(config.ProviderConfig{Prompt: "ok", Model: *model, ReasoningEffort: "low"}).Trigger(context.Background(), *dry)
	r.DurationMs = time.Since(start).Milliseconds()
	if err != nil {
		r.Category = classify(err)
		return r, 1
	}
	if *dry {
		r.Category = "dry_run"
	} else {
		r.Category = "completed"
		r.Completed = true
	}
	return r, 0
}

func main() {
	r, code := run(os.Args[1:])
	// Raw provider errors can contain terminal output. Emit only stable categories.
	_ = json.NewEncoder(os.Stdout).Encode(r)
	os.Exit(code)
}
