//go:build !windows

package provider

func codexExecutable() string { return "codex" }

func codexSessionHome() string { return defaultCodexSessionHome() }
