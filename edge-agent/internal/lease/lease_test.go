package lease

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"
)

var fixtureNow = time.Date(2026, 7, 22, 1, 0, 0, 0, time.UTC)

func TestSignVerifyAndCanonicalOrder(t *testing.T) {
	privateKey, publicKey := deterministicKey(t)
	value, err := New(
		"home-egress-1",
		"home.example.invalid",
		netip.MustParseAddr("203.0.113.9"),
		10,
		time.Date(2026, 7, 22, 0, 0, 0, 0, time.UTC),
		2*time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}

	signed, err := Sign(value, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	got, err := ParseAndVerify(
		signed,
		publicKey,
		"home-egress-1",
		"home.example.invalid",
		9,
		fixtureNow,
	)
	if err != nil {
		t.Fatal(err)
	}
	if got.Sequence != 10 || got.IPv4 != "203.0.113.9" {
		t.Fatalf("unexpected verified lease: %#v", got)
	}

	wantCanonical := `{"expires_at":"2026-07-22T02:00:00Z","home_name":"home.example.invalid","ipv4":"203.0.113.9","issued_at":"2026-07-22T00:00:00Z","key_id":"home-egress-1","sequence":10,"version":1}`
	if got := string(canonicalUnsigned(value)); got != wantCanonical {
		t.Fatalf("canonical JSON\n got: %s\nwant: %s", got, wantCanonical)
	}
}

func TestNewEmitsWorkerCompatibleWholeSecondTimestamps(t *testing.T) {
	value, err := New(
		"home-egress-1",
		"home.example.invalid",
		netip.MustParseAddr("203.0.113.9"),
		10,
		time.Date(2026, 7, 22, 0, 0, 0, 987654321, time.UTC),
		2*time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	if value.IssuedAt != "2026-07-22T00:00:00Z" ||
		value.ExpiresAt != "2026-07-22T02:00:00Z" {
		t.Fatalf("timestamps are not whole-second RFC3339: %#v", value)
	}
}

func TestVerifiesNodeSignedFixture(t *testing.T) {
	raw, err := os.ReadFile("../../testdata/node-signed-egress-lease.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		PublicKey string          `json:"public_key"`
		Lease     json.RawMessage `json:"lease"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	publicKey, err := base64.StdEncoding.Strict().DecodeString(fixture.PublicKey)
	if err != nil {
		t.Fatal(err)
	}

	got, err := ParseAndVerify(
		fixture.Lease,
		ed25519.PublicKey(publicKey),
		"home-egress-1",
		"home.example.invalid",
		9,
		fixtureNow,
	)
	if err != nil {
		t.Fatal(err)
	}
	if got.Sequence != 10 {
		t.Fatalf("sequence = %d, want 10", got.Sequence)
	}
}

func TestParseAndVerifyRejectsTrustAndReplayFailures(t *testing.T) {
	privateKey, publicKey := deterministicKey(t)
	signed := signedLease(t, privateKey, 10, fixtureNow.Add(-time.Hour), 2*time.Hour)

	var value Document
	if err := json.Unmarshal(signed, &value); err != nil {
		t.Fatal(err)
	}
	signature, err := base64.StdEncoding.Strict().DecodeString(value.Signature)
	if err != nil {
		t.Fatal(err)
	}
	signature[0] ^= 0xff
	value.Signature = base64.StdEncoding.EncodeToString(signature)
	tampered, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		name         string
		raw          []byte
		keyID        string
		homeName     string
		minimum      int64
		wantCategory string
	}{
		{name: "signature", raw: tampered, keyID: "home-egress-1", homeName: "home.example.invalid", minimum: 9, wantCategory: "signature"},
		{name: "key id", raw: signed, keyID: "home-egress-2", homeName: "home.example.invalid", minimum: 9, wantCategory: "key_id"},
		{name: "home name", raw: signed, keyID: "home-egress-1", homeName: "other.example.invalid", minimum: 9, wantCategory: "home_name"},
		{name: "rollback", raw: signed, keyID: "home-egress-1", homeName: "home.example.invalid", minimum: 11, wantCategory: "sequence"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := ParseAndVerify(tc.raw, publicKey, tc.keyID, tc.homeName, tc.minimum, fixtureNow)
			if err == nil || !strings.Contains(err.Error(), tc.wantCategory) {
				t.Fatalf("error = %v, want category %q", err, tc.wantCategory)
			}
		})
	}
}

func TestParseAndVerifyRejectsInvalidTimeWindows(t *testing.T) {
	privateKey, publicKey := deterministicKey(t)
	tests := []struct {
		name     string
		issuedAt time.Time
		validity time.Duration
		want     string
	}{
		{name: "expired", issuedAt: fixtureNow.Add(-3 * time.Hour), validity: 2 * time.Hour, want: "expired"},
		{name: "future", issuedAt: fixtureNow.Add(6 * time.Minute), validity: 2 * time.Hour, want: "future"},
		{name: "oversized", issuedAt: fixtureNow, validity: 126 * time.Minute, want: "validity"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var raw []byte
			if tc.validity > maximumWindow {
				raw = signedUncheckedLease(t, privateKey, 10, tc.issuedAt, tc.validity)
			} else {
				raw = signedLease(t, privateKey, 10, tc.issuedAt, tc.validity)
			}
			_, err := ParseAndVerify(raw, publicKey, "home-egress-1", "home.example.invalid", 9, fixtureNow)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %v, want category %q", err, tc.want)
			}
		})
	}
}

func TestStrictDocumentParsingAndDeploymentIPv4(t *testing.T) {
	privateKey, publicKey := deterministicKey(t)
	raw := signedLease(t, privateKey, 10, fixtureNow.Add(-time.Hour), 2*time.Hour)
	withUnknown := bytes.Replace(raw, []byte(`"version":1`), []byte(`"unknown":true,"version":1`), 1)
	if _, err := ParseAndVerify(withUnknown, publicKey, "home-egress-1", "home.example.invalid", 9, fixtureNow); err == nil || !strings.Contains(err.Error(), "fields") {
		t.Fatalf("unknown-field error = %v", err)
	}

	for _, address := range []string{"203.0.113.9", "10.0.0.1", "100.64.0.9", "127.0.0.1", "2001:db8::1"} {
		if err := ValidateDeploymentIPv4(netip.MustParseAddr(address)); err == nil {
			t.Fatalf("ValidateDeploymentIPv4(%s) succeeded", address)
		}
	}
	if err := ValidateDeploymentIPv4(netip.MustParseAddr("8.8.8.8")); err != nil {
		t.Fatalf("public deployment IPv4 rejected: %v", err)
	}
}

func TestGenerateKeyPairProducesPKCS8AndMaskIsRedacted(t *testing.T) {
	random := bytes.NewReader(bytes.Repeat([]byte{0x42}, ed25519.SeedSize))
	privatePEM, publicKey, err := GenerateKeyPair(random)
	if err != nil {
		t.Fatal(err)
	}
	privateKey, err := ParsePrivateKeyPKCS8(privatePEM)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(privateKey.Public().(ed25519.PublicKey), publicKey) {
		t.Fatal("generated public key does not match private key")
	}
	if got := MaskIPv4("203.0.113.9"); got != "***.***.***.9" {
		t.Fatalf("MaskIPv4 = %q", got)
	}
}

func deterministicKey(t *testing.T) (ed25519.PrivateKey, ed25519.PublicKey) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for index := range seed {
		seed[index] = byte(index)
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	return privateKey, privateKey.Public().(ed25519.PublicKey)
}

func signedLease(t *testing.T, privateKey ed25519.PrivateKey, sequence int64, issuedAt time.Time, validity time.Duration) []byte {
	t.Helper()
	value, err := New(
		"home-egress-1",
		"home.example.invalid",
		netip.MustParseAddr("203.0.113.9"),
		sequence,
		issuedAt,
		validity,
	)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := Sign(value, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func signedUncheckedLease(t *testing.T, privateKey ed25519.PrivateKey, sequence int64, issuedAt time.Time, validity time.Duration) []byte {
	t.Helper()
	value := Document{
		Version:   Version,
		KeyID:     "home-egress-1",
		HomeName:  "home.example.invalid",
		IPv4:      "203.0.113.9",
		Sequence:  sequence,
		IssuedAt:  issuedAt.UTC().Format(time.RFC3339Nano),
		ExpiresAt: issuedAt.UTC().Add(validity).Format(time.RFC3339Nano),
	}
	value.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, canonicalUnsigned(value)))
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
