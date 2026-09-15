package provider

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCodexSessionObserverAcceptsCompletedAssistantTurn(t *testing.T) {
	observer, path := newTestCodexSessionObserver(t, "ok")
	writeTestCodexSession(t, path,
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ok"}]}}`,
		`{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"OK"}}`)
	complete, err := observer.result()
	if !complete || err != nil {
		t.Fatalf("result = complete %v, err %v; want verified success", complete, err)
	}
}

func TestCodexSessionObserverRejectsTurnError(t *testing.T) {
	observer, path := newTestCodexSessionObserver(t, "ok")
	writeTestCodexSession(t, path,
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ok"}]}}`,
		`{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null,"error":{"message":"refresh token was revoked","codex_error_info":"unauthorized"}}}`)
	complete, err := observer.result()
	if !complete || err == nil || !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("result = complete %v, err %v; want unauthorized failure", complete, err)
	}
}

func TestCodexSessionObserverRejectsMissingAssistantResponse(t *testing.T) {
	observer, path := newTestCodexSessionObserver(t, "ok")
	writeTestCodexSession(t, path,
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"ok"}]}}`,
		`{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null}}`)
	complete, err := observer.result()
	if !complete || err == nil || !strings.Contains(err.Error(), "without an assistant response") {
		t.Fatalf("result = complete %v, err %v; want missing-response failure", complete, err)
	}
}

func TestCodexSessionObserverIgnoresUnrelatedPrompt(t *testing.T) {
	observer, path := newTestCodexSessionObserver(t, "ok")
	writeTestCodexSession(t, path,
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"different"}]}}`,
		`{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"OK"}}`)
	complete, err := observer.result()
	if complete || err != nil {
		t.Fatalf("result = complete %v, err %v; want unrelated session ignored", complete, err)
	}
}

func newTestCodexSessionObserver(t *testing.T, prompt string) (*codexSessionObserver, string) {
	t.Helper()
	home := t.TempDir()
	existing := filepath.Join(home, "sessions", "existing.jsonl")
	if err := os.MkdirAll(filepath.Dir(existing), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(existing, []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	observer, err := newCodexSessionObserver(home, prompt)
	if err != nil {
		t.Fatal(err)
	}
	return observer, filepath.Join(home, "sessions", "new.jsonl")
}

func writeTestCodexSession(t *testing.T, path string, lines ...string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}
