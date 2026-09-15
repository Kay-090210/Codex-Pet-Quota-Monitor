//go:build windows

package provider

import (
	"os"
	"path/filepath"
)

// codexExecutable prefers the engine shipped with Codex Desktop. It shares the
// desktop client's authentication and is updated with the app, avoiding a
// separate stale npm CLI. PATH remains the fallback for non-Desktop installs.
func codexExecutable() string {
	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		return "codex"
	}
	if path := newestDesktopCodex(filepath.Join(localAppData, "OpenAI", "Codex", "bin")); path != "" {
		return path
	}
	return "codex"
}

func codexSessionHome() string {
	if home := resolveLimitPingCodexHome(os.Environ(), os.Executable); home != "" {
		return home
	}
	return defaultCodexSessionHome()
}

func newestDesktopCodex(binDir string) string {
	candidates := []string{filepath.Join(binDir, "codex.exe")}
	nested, _ := filepath.Glob(filepath.Join(binDir, "*", "codex.exe"))
	candidates = append(candidates, nested...)

	var newest string
	var newestMod int64
	for _, candidate := range candidates {
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() {
			continue
		}
		if mod := info.ModTime().UnixNano(); newest == "" || mod > newestMod {
			newest, newestMod = candidate, mod
		}
	}
	return newest
}
