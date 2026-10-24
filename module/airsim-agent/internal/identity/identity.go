package identity

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
)

type record struct {
	Schema    int    `json:"schema_version"`
	Module    string `json:"module_id"`
	Algorithm string `json:"algorithm"`
	Seed      string `json:"seed_base64"`
	Public    string `json:"public_key_base64"`
}
type Identity struct {
	ModuleID string
	key      ed25519.PrivateKey
}

var invalid = errors.New("identity_invalid")
var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func UUID() (string, error) {
	b := make([]byte, 16)
	if _, e := rand.Read(b); e != nil {
		return "", e
	}
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[:4], b[4:6], b[6:8], b[8:10], b[10:]), nil
}
func decode(b []byte) (Identity, error) {
	if len(b) > 4096 {
		return Identity{}, invalid
	}
	d := json.NewDecoder(bytes.NewReader(b))
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return Identity{}, invalid
	}
	seen := map[string]bool{}
	for d.More() {
		t, e = d.Token()
		if e != nil {
			return Identity{}, invalid
		}
		k, ok := t.(string)
		if !ok || seen[k] {
			return Identity{}, invalid
		}
		switch k {
		case "schema_version", "module_id", "algorithm", "seed_base64", "public_key_base64":
		default:
			return Identity{}, invalid
		}
		seen[k] = true
		var v json.RawMessage
		if d.Decode(&v) != nil {
			return Identity{}, invalid
		}
	}
	if _, e = d.Token(); e != nil {
		return Identity{}, invalid
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return Identity{}, invalid
	}
	var r record
	d = json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&r) != nil || len(seen) != 5 || r.Schema != 1 || r.Algorithm != "ed25519" || !uuidPattern.MatchString(r.Module) {
		return Identity{}, invalid
	}
	seed, e := base64.StdEncoding.Strict().DecodeString(r.Seed)
	if e != nil || len(seed) != 32 || base64.StdEncoding.EncodeToString(seed) != r.Seed {
		return Identity{}, invalid
	}
	pub, e := base64.StdEncoding.Strict().DecodeString(r.Public)
	if e != nil || len(pub) != 32 || base64.StdEncoding.EncodeToString(pub) != r.Public {
		return Identity{}, invalid
	}
	key := ed25519.NewKeyFromSeed(seed)
	if !bytes.Equal(pub, key.Public().(ed25519.PublicKey)) {
		return Identity{}, invalid
	}
	return Identity{r.Module, key}, nil
}

// LoadOrCreate must be called while the process holds the instance lock.
func LoadOrCreate(dir string) (Identity, error) {
	if e := os.MkdirAll(dir, 0700); e != nil {
		return Identity{}, invalid
	}
	info, e := os.Lstat(dir)
	if e != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0700 {
		return Identity{}, invalid
	}
	path := filepath.Join(dir, "identity.json")
	info, e = os.Lstat(path)
	if e == nil {
		if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 || info.Size() > 4096 {
			return Identity{}, invalid
		}
		b, e := os.ReadFile(path)
		if e != nil {
			return Identity{}, invalid
		}
		return decode(b)
	}
	if !os.IsNotExist(e) {
		return Identity{}, invalid
	}
	leftovers, e := filepath.Glob(filepath.Join(dir, ".identity-*"))
	if e != nil || len(leftovers) != 0 {
		return Identity{}, invalid
	}
	id, e := UUID()
	if e != nil {
		return Identity{}, e
	}
	pub, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		return Identity{}, e
	}
	b, e := json.Marshal(record{1, id, "ed25519", base64.StdEncoding.EncodeToString(key.Seed()), base64.StdEncoding.EncodeToString(pub)})
	if e != nil {
		return Identity{}, e
	}
	f, e := os.CreateTemp(dir, ".identity-*")
	if e != nil {
		return Identity{}, e
	}
	defer f.Close()
	// Leave incomplete creation evidence on failure. Never overwrite an existing identity.
	if e = f.Chmod(0600); e != nil {
		return Identity{}, e
	}
	if _, e = f.Write(b); e != nil {
		return Identity{}, e
	}
	if e = f.Sync(); e != nil {
		return Identity{}, e
	}
	if e = f.Close(); e != nil {
		return Identity{}, e
	}
	if e = os.Link(f.Name(), path); e != nil {
		return Identity{}, invalid
	}
	if e = os.Remove(f.Name()); e != nil {
		return Identity{}, e
	}
	d, e := os.Open(dir)
	if e != nil {
		return Identity{}, e
	}
	defer d.Close()
	if e = d.Sync(); e != nil {
		return Identity{}, e
	}
	return Identity{id, key}, nil
}

// CommandDigest keeps seed material inside the identity package. The fixed
// domain precedes the canonical complete request; neither input is logged.
func (i Identity) CommandDigest(canonical []byte) string {
	m := hmac.New(sha256.New, i.key.Seed())
	m.Write([]byte("airsim-r2-command-v1"))
	m.Write(canonical)
	return hex.EncodeToString(m.Sum(nil))
}
