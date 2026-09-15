# limitping single-turn helper

Vendored from the local limitping source snapshot, module
`github.com/wavever/CCLimitPing` (upstream: https://github.com/wavever/CCLimitPing).
The original MIT license is retained in `LICENSE`. `UPSTREAM-SHA256.txt` records
each copied file's SHA-256 before the change below. This snapshot includes local
limitping changes; it is not claimed to match an upstream release or commit.

The copied packages are `provider`, `auth`, `activity`, `config`, and `usage`,
including their tests. The original `go.mod` and `go.sum` are preserved. No
scheduler, reset-credit action, or limitping command entrypoint is invoked.

## Differences

1. `cmd/pet-ping/main.go` is a thin adapter: set the two profile environment
   variables, change to an existing fixed working directory, then invoke
   `provider.NewCodex(...).Trigger(...)` with prompt `ok`, the selected model,
   reasoning effort `low`, and no extra arguments.
2. In `internal/provider/codex.go`, `triggerCodex` returns on
   `terminal || err != nil`, rather than `terminal` only. This preserves a failed
   session result instead of overwriting it with successful terminal shutdown.
3. No changes to the copied ConPTY implementation, command arguments, environment
   filter, session observation, or normal shutdown path.

## Build and interface

Run `Build.ps1` here with Go matching `go.mod` (or a newer compatible toolchain).
It runs offline/unit tests then writes `bin/codex-pet-ping.exe` at repository root.
These tests **do not certify a real CLI request or quota-window activation**.
Real end-to-end verification is separate and consumes a small amount of quota.

Flags: `--home ABSOLUTE_EXISTING_PROFILE --workdir ABSOLUTE_EXISTING_TRUSTED_DIR
--model MODEL [--dry-run] [--wait-for-parent]`.

`--wait-for-parent` reads `go` followed by newline from stdin before starting the
provider; EOF or another value exits without a request. The parent uses this to
assign a Windows job object before any CLI child can be spawned.

The working directory must already be trusted in the selected CLI profile;
the helper does not inject trust overrides or bypass startup prompts.
The profile is configurable and does not require a limitping installation.

Stdout is one JSON object with exactly `completed`, `dryRun`, `category`, and
`durationMs`. Successful real completion sets `completed=true`; dry-run does not.
Exit 0 indicates completed/dry-run; exit 1 indicates failure. Failure categories
are `authentication`, `timeout`, `cli_start`, `session_failed`, and
`invalid_configuration`. Raw error text, terminal output, and credentials are
not emitted. `completed` is evidence of a successful observed session result,
not proof of a new quota window; the monitor must read quota separately.
