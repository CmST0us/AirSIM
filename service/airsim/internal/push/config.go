package push

import (
	"context"
	"errors"
)

type Config struct {
	TeamID, BundleID                   string
	KeyID, KeyFile                     string
	SandboxKeyID, SandboxKeyFile       string
	ProductionKeyID, ProductionKeyFile string
}

type environmentProvider struct {
	sandbox, production *Provider
}

// LoadConfig accepts either an existing shared key or a complete environment pair.
func LoadConfig(c Config) (Sender, error) {
	split := c.SandboxKeyID != "" || c.SandboxKeyFile != "" || c.ProductionKeyID != "" || c.ProductionKeyFile != ""
	if !split {
		p, err := Load(c.KeyID, c.TeamID, c.BundleID, c.KeyFile)
		if err != nil || p == nil {
			return nil, err
		}
		return p, nil
	}
	if c.KeyID != "" || c.KeyFile != "" {
		return nil, errors.New("apns_config_mixed_keys")
	}
	if c.SandboxKeyID == "" || c.SandboxKeyFile == "" || c.ProductionKeyID == "" || c.ProductionKeyFile == "" {
		return nil, errors.New("apns_config_incomplete")
	}
	sandbox, err := Load(c.SandboxKeyID, c.TeamID, c.BundleID, c.SandboxKeyFile)
	if err != nil {
		return nil, err
	}
	production, err := Load(c.ProductionKeyID, c.TeamID, c.BundleID, c.ProductionKeyFile)
	if err != nil {
		return nil, err
	}
	return &environmentProvider{sandbox: sandbox, production: production}, nil
}

func (p *environmentProvider) Send(ctx context.Context, n Notification) (Result, error) {
	switch n.Environment {
	case "sandbox":
		return p.sandbox.Send(ctx, n)
	case "production":
		return p.production.Send(ctx, n)
	default:
		return Result{}, errors.New("apns_environment_invalid")
	}
}
