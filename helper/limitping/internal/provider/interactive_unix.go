//go:build !windows

package provider

import (
	"context"
	"os"
	"os/exec"

	"github.com/creack/pty"
)

type unixInteractivePTY struct {
	file *os.File
	cmd  *exec.Cmd
}

func startPlatformPTY(ctx context.Context, name string, args ...string) (interactivePTY, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	file, err := pty.Start(cmd)
	if err != nil {
		return nil, err
	}
	return &unixInteractivePTY{file: file, cmd: cmd}, nil
}

func (p *unixInteractivePTY) Read(b []byte) (int, error)  { return p.file.Read(b) }
func (p *unixInteractivePTY) Write(b []byte) (int, error) { return p.file.Write(b) }
func (p *unixInteractivePTY) Close() error                { return p.file.Close() }
func (p *unixInteractivePTY) Wait() error                 { return p.cmd.Wait() }

func (p *unixInteractivePTY) Kill() error {
	if p.cmd.Process == nil {
		return nil
	}
	return p.cmd.Process.Kill()
}
