package identity

import (
	"crypto"
	"crypto/ed25519"
	"io"
)

// Signer exposes signing operations, never the private key or seed.
func (i Identity) Signer() crypto.Signer { return identitySigner{i} }

type identitySigner struct{ identity Identity }

func (s identitySigner) Public() crypto.PublicKey {
	return append(ed25519.PublicKey(nil), s.identity.key.Public().(ed25519.PublicKey)...)
}
func (s identitySigner) Sign(random io.Reader, message []byte, opts crypto.SignerOpts) ([]byte, error) {
	return s.identity.key.Sign(random, message, opts)
}
