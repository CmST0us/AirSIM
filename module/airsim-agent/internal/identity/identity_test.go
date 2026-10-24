package identity

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPersistenceAndValidation(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "config")
	a, e := LoadOrCreate(dir)
	if e != nil {
		t.Fatal(e)
	}
	b, e := LoadOrCreate(dir)
	if e != nil || a.ModuleID != b.ModuleID {
		t.Fatal("identity changed")
	}
	path := filepath.Join(dir, "identity.json")
	raw, e := os.ReadFile(path)
	if e != nil {
		t.Fatal(e)
	}
	var r map[string]any
	if json.Unmarshal(raw, &r) != nil {
		t.Fatal("json")
	}
	cases := map[string][]byte{"partial": raw[:20], "trailing": append(append([]byte{}, raw...), []byte("{}")...), "duplicate": []byte(strings.Replace(string(raw), `"schema_version":1`, `"schema_version":1,"schema_version":1`, 1)), "unknown": []byte(strings.Replace(string(raw), `"schema_version":1`, `"unknown":1,"schema_version":1`, 1)), "key": []byte(strings.Replace(string(raw), `"algorithm":"ed25519"`, `"algorithm":"rsa"`, 1)), "oversize": make([]byte, 4097)}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if os.WriteFile(path, data, 0600) != nil {
				t.Fatal("write")
			}
			if _, e := LoadOrCreate(dir); e == nil {
				t.Fatal("accepted invalid identity")
			}
			got, _ := os.ReadFile(path)
			if string(got) != string(data) {
				t.Fatal("replaced corrupt identity")
			}
		})
	}
	os.Remove(path)
	target := filepath.Join(t.TempDir(), "identity.json")
	os.WriteFile(target, raw, 0600)
	os.Symlink(target, path)
	if _, e := LoadOrCreate(dir); e == nil {
		t.Fatal("accepted symlink")
	}
}
func TestPartialCreationAndBootIDs(t *testing.T) {
	dir := t.TempDir()
	os.Chmod(dir, 0700)
	os.WriteFile(filepath.Join(dir, ".identity-partial"), []byte("x"), 0600)
	if _, e := LoadOrCreate(dir); e == nil {
		t.Fatal("partial init regenerated")
	}
	a, _ := UUID()
	b, _ := UUID()
	if a == b || !uuidPattern.MatchString(a) {
		t.Fatal("bad boot uuid")
	}
}

func TestDerivedPublicKeyAndStrictTypes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "config")
	if _, e := LoadOrCreate(dir); e != nil {
		t.Fatal(e)
	}
	raw, e := os.ReadFile(filepath.Join(dir, "identity.json"))
	if e != nil {
		t.Fatal(e)
	}
	var r map[string]any
	json.Unmarshal(raw, &r)
	for _, key := range []string{"schema_version", "module_id", "algorithm", "seed_base64", "public_key_base64"} {
		t.Run(key, func(t *testing.T) {
			copy := map[string]any{}
			for k, v := range r {
				copy[k] = v
			}
			copy[key] = false
			b, _ := json.Marshal(copy)
			if _, e := decode(b); e == nil {
				t.Fatal("accepted wrong field type")
			}
		})
	}
	r["public_key_base64"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	b, _ := json.Marshal(r)
	if _, e := decode(b); e == nil {
		t.Fatal("accepted mismatched public key")
	}
}

func TestFieldNamesAreCaseSensitive(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "config")
	if _, e := LoadOrCreate(dir); e != nil {
		t.Fatal(e)
	}
	raw, e := os.ReadFile(filepath.Join(dir, "identity.json"))
	if e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"schema_version", "module_id", "algorithm", "seed_base64", "public_key_base64"} {
		t.Run(key, func(t *testing.T) {
			changed := strings.Replace(string(raw), `"`+key+`":`, `"`+strings.ToUpper(key)+`":`, 1)
			if _, e := decode([]byte(changed)); e == nil {
				t.Fatal("accepted case-insensitive field")
			}
		})
	}
	mixed := strings.Replace(string(raw), `"schema_version":`, `"Schema_version":`, 1)
	if _, e := decode([]byte(mixed)); e == nil {
		t.Fatal("accepted mixed-case field")
	}
}

func TestCommandDigestStablePrivateAndInputSensitive(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "identity")
	a, e := LoadOrCreate(dir)
	if e != nil {
		t.Fatal(e)
	}
	b, e := LoadOrCreate(dir)
	if e != nil {
		t.Fatal(e)
	}
	input := []byte(`{"synthetic":"request"}`)
	digest := a.CommandDigest(input)
	if len(digest) != 64 || digest != b.CommandDigest(input) || digest == a.CommandDigest(append(input, ' ')) {
		t.Fatal("digest contract")
	}
	other, e := LoadOrCreate(filepath.Join(t.TempDir(), "other"))
	if e != nil {
		t.Fatal(e)
	}
	if digest == other.CommandDigest(input) {
		t.Fatal("digest not identity bound")
	}
}
