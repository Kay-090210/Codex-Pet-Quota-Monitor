package provider

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// codexSessionObserver verifies the turn through the session artifact written
// by Codex. This is stronger than watching the TUI process: the TUI can remain
// alive and exit cleanly even when task_complete contains an authentication
// error and no assistant message.
type codexSessionObserver struct {
	home     string
	prompt   string
	existing map[string]struct{}
}

func newCodexSessionObserver(home, prompt string) (*codexSessionObserver, error) {
	if strings.TrimSpace(home) == "" {
		return nil, fmt.Errorf("Codex home is empty")
	}
	existing, err := codexSessionFiles(home)
	if err != nil {
		return nil, err
	}
	return &codexSessionObserver{home: home, prompt: strings.TrimSpace(prompt), existing: existing}, nil
}

func defaultCodexSessionHome() string {
	if home := strings.TrimSpace(os.Getenv("CODEX_HOME")); home != "" {
		return home
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex")
}

func codexSessionFiles(home string) (map[string]struct{}, error) {
	root := filepath.Join(home, "sessions")
	files := make(map[string]struct{})
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !entry.IsDir() && strings.EqualFold(filepath.Ext(path), ".jsonl") {
			files[path] = struct{}{}
		}
		return nil
	})
	if os.IsNotExist(err) {
		return files, nil
	}
	return files, err
}

// result reports whether a matching new session has reached task_complete.
func (o *codexSessionObserver) result() (bool, error) {
	files, err := codexSessionFiles(o.home)
	if err != nil {
		return true, fmt.Errorf("reading Codex session results: %w", err)
	}
	for path := range files {
		if _, existed := o.existing[path]; existed {
			continue
		}
		complete, matched, err := readCodexSessionResult(path, o.prompt)
		if err != nil {
			return true, fmt.Errorf("reading Codex session result: %w", err)
		}
		if matched && complete {
			return true, nil
		}
		if matched && err != nil {
			return true, err
		}
	}
	return false, nil
}

type codexSessionRecord struct {
	Type    string `json:"type"`
	Payload struct {
		Type    string `json:"type"`
		Role    string `json:"role"`
		Content []struct {
			Text string `json:"text"`
		} `json:"content"`
		LastAgentMessage *string `json:"last_agent_message"`
		Error            *struct {
			Message        string `json:"message"`
			CodexErrorInfo string `json:"codex_error_info"`
		} `json:"error"`
	} `json:"payload"`
}

func readCodexSessionResult(path, prompt string) (complete, matched bool, resultErr error) {
	f, err := os.Open(path)
	if err != nil {
		return false, false, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		var record codexSessionRecord
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			// The final line may still be in flight; a later poll will retry it.
			continue
		}
		if record.Type == "response_item" && record.Payload.Role == "user" {
			for _, item := range record.Payload.Content {
				if strings.TrimSpace(item.Text) == prompt {
					matched = true
				}
			}
		}
		if record.Type != "event_msg" || record.Payload.Type != "task_complete" {
			continue
		}
		if !matched {
			return false, false, nil
		}
		if record.Payload.Error != nil {
			code := strings.TrimSpace(record.Payload.Error.CodexErrorInfo)
			message := truncate([]byte(record.Payload.Error.Message), 300)
			if code != "" {
				return false, true, fmt.Errorf("codex turn failed (%s): %s", code, message)
			}
			return false, true, fmt.Errorf("codex turn failed: %s", message)
		}
		if record.Payload.LastAgentMessage == nil || strings.TrimSpace(*record.Payload.LastAgentMessage) == "" {
			return false, true, fmt.Errorf("codex turn completed without an assistant response")
		}
		return true, true, nil
	}
	if err := scanner.Err(); err != nil {
		return false, false, err
	}
	return false, matched, nil
}
