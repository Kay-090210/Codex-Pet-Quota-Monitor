package provider

import (
	"context"
	"io"
)

// interactivePTY is the small cross-platform surface the provider trigger
// needs. Unix implementations use a traditional PTY; Windows uses ConPTY.
type interactivePTY interface {
	io.Reader
	io.Writer
	io.Closer
	Wait() error
	Kill() error
}

func startInteractivePTY(ctx context.Context, name string, args ...string) (interactivePTY, error) {
	return startPlatformPTY(ctx, name, args...)
}
