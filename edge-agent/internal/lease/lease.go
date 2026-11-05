package lease

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"strings"
	"time"
)

const (
	Version       = 1
	MaximumBytes  = 4096
	maximumWindow = 125 * time.Minute
	futureSkew    = 5 * time.Minute
)

type Document struct {
	Version   int    `json:"version"`
	KeyID     string `json:"key_id"`
	HomeName  string `json:"home_name"`
	IPv4      string `json:"ipv4"`
	Sequence  int64  `json:"sequence"`
	IssuedAt  string `json:"issued_at"`
	ExpiresAt string `json:"expires_at"`
	Signature string `json:"signature,omitempty"`
}

type unsignedDocument struct {
	ExpiresAt string `json:"expires_at"`
	HomeName  string `json:"home_name"`
	IPv4      string `json:"ipv4"`
	IssuedAt  string `json:"issued_at"`
	KeyID     string `json:"key_id"`
	Sequence  int64  `json:"sequence"`
	Version   int    `json:"version"`
}

func New(
	keyID string,
	homeName string,
	address netip.Addr,
	sequence int64,
	issuedAt time.Time,
	validity time.Duration,
) (Document, error) {
	if validity <= 0 || validity > maximumWindow {
		return Document{}, errors.New("lease validity is invalid")
	}
	issuedAt = issuedAt.UTC().Truncate(time.Second)
	document := Document{
		Version:   Version,
		KeyID:     keyID,
		HomeName:  homeName,
		IPv4:      address.String(),
		Sequence:  sequence,
		IssuedAt:  issuedAt.Format(time.RFC3339),
		ExpiresAt: issuedAt.Add(validity).Format(time.RFC3339),
	}
	if _, _, err := validateFields(document); err != nil {
		return Document{}, err
	}
	return document, nil
}

func Sign(document Document, privateKey ed25519.PrivateKey) ([]byte, error) {
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, errors.New("lease private key is invalid")
	}
	if document.Signature != "" {
		return nil, errors.New("lease signature must be empty before signing")
	}
	if _, _, err := validateFields(document); err != nil {
		return nil, err
	}
	document.Signature = base64.StdEncoding.EncodeToString(
		ed25519.Sign(privateKey, canonicalUnsigned(document)),
	)
	return json.Marshal(document)
}

func ParseAndVerify(
	raw []byte,
	publicKey ed25519.PublicKey,
	expectedKeyID string,
	expectedHomeName string,
	minimumSequence int64,
	now time.Time,
) (Document, error) {
	if len(raw) == 0 || len(raw) > MaximumBytes {
		return Document{}, errors.New("lease size is invalid")
	}
	if len(publicKey) != ed25519.PublicKeySize {
		return Document{}, errors.New("lease public key is invalid")
	}
	if minimumSequence < 0 {
		return Document{}, errors.New("lease minimum sequence is invalid")
	}
	if now.IsZero() {
		return Document{}, errors.New("lease verification time is invalid")
	}

	var document Document
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return Document{}, errors.New("lease fields are invalid")
	}
	if err := requireJSONEOF(decoder); err != nil {
		return Document{}, err
	}
	issuedAt, expiresAt, err := validateFields(document)
	if err != nil {
		return Document{}, err
	}
	if document.KeyID != expectedKeyID {
		return Document{}, errors.New("lease key_id does not match")
	}
	if document.HomeName != expectedHomeName {
		return Document{}, errors.New("lease home_name does not match")
	}
	if document.Sequence < minimumSequence {
		return Document{}, errors.New("lease sequence rolled back")
	}
	clock := now.UTC()
	if issuedAt.After(clock.Add(futureSkew)) {
		return Document{}, errors.New("lease issued_at is too far in the future")
	}
	if !expiresAt.After(clock) {
		return Document{}, errors.New("lease is expired")
	}

	signature, err := base64.StdEncoding.Strict().DecodeString(document.Signature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return Document{}, errors.New("lease signature is invalid")
	}
	if !ed25519.Verify(publicKey, canonicalUnsigned(document), signature) {
		return Document{}, errors.New("lease signature is invalid")
	}
	return document, nil
}

func GenerateKeyPair(random io.Reader) ([]byte, ed25519.PublicKey, error) {
	if random == nil {
		return nil, nil, errors.New("lease random source is missing")
	}
	publicKey, privateKey, err := ed25519.GenerateKey(random)
	if err != nil {
		return nil, nil, fmt.Errorf("generate lease key: %w", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, nil, fmt.Errorf("marshal lease key: %w", err)
	}
	privatePEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	if len(privatePEM) == 0 {
		return nil, nil, errors.New("encode lease key failed")
	}
	return privatePEM, publicKey, nil
}

func ParsePrivateKeyPKCS8(data []byte) (ed25519.PrivateKey, error) {
	block, rest := pem.Decode(data)
	if block == nil || block.Type != "PRIVATE KEY" || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("lease private key PEM is invalid")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("lease private key PKCS8 is invalid")
	}
	privateKey, ok := parsed.(ed25519.PrivateKey)
	if !ok || len(privateKey) != ed25519.PrivateKeySize {
		return nil, errors.New("lease private key type is invalid")
	}
	return privateKey, nil
}

func ValidateDeploymentIPv4(address netip.Addr) error {
	if !address.IsValid() || !address.Is4() || !address.IsGlobalUnicast() ||
		address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() ||
		address.IsMulticast() || address.IsUnspecified() {
		return errors.New("deployment IPv4 is not globally routable")
	}
	for _, prefix := range nonDeploymentPrefixes {
		if prefix.Contains(address) {
			return errors.New("deployment IPv4 is reserved")
		}
	}
	return nil
}

func MaskIPv4(value string) string {
	address, err := netip.ParseAddr(value)
	if err != nil || !address.Is4() {
		return "invalid"
	}
	octets := address.As4()
	return fmt.Sprintf("***.***.***.%d", octets[3])
}

func canonicalUnsigned(document Document) []byte {
	value := unsignedDocument{
		ExpiresAt: document.ExpiresAt,
		HomeName:  document.HomeName,
		IPv4:      document.IPv4,
		IssuedAt:  document.IssuedAt,
		KeyID:     document.KeyID,
		Sequence:  document.Sequence,
		Version:   document.Version,
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return encoded
}

func validateFields(document Document) (time.Time, time.Time, error) {
	if document.Version != Version {
		return time.Time{}, time.Time{}, errors.New("lease version is unsupported")
	}
	if !validKeyID(document.KeyID) {
		return time.Time{}, time.Time{}, errors.New("lease key_id is invalid")
	}
	if !validHomeName(document.HomeName) {
		return time.Time{}, time.Time{}, errors.New("lease home_name is invalid")
	}
	address, err := netip.ParseAddr(document.IPv4)
	if err != nil || !address.Is4() || address.String() != document.IPv4 {
		return time.Time{}, time.Time{}, errors.New("lease ipv4 is invalid")
	}
	if document.Sequence <= 0 {
		return time.Time{}, time.Time{}, errors.New("lease sequence is invalid")
	}
	issuedAt, err := parseTimestamp(document.IssuedAt, "issued_at")
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	expiresAt, err := parseTimestamp(document.ExpiresAt, "expires_at")
	if err != nil {
		return time.Time{}, time.Time{}, err
	}
	validity := expiresAt.Sub(issuedAt)
	if validity <= 0 || validity > maximumWindow {
		return time.Time{}, time.Time{}, errors.New("lease validity is invalid")
	}
	if document.Signature != "" {
		signature, err := base64.StdEncoding.Strict().DecodeString(document.Signature)
		if err != nil || len(signature) != ed25519.SignatureSize {
			return time.Time{}, time.Time{}, errors.New("lease signature is invalid")
		}
	}
	return issuedAt, expiresAt, nil
}

func parseTimestamp(value string, field string) (time.Time, error) {
	if !strings.HasSuffix(value, "Z") {
		return time.Time{}, fmt.Errorf("lease %s is invalid", field)
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("lease %s is invalid", field)
	}
	return parsed.UTC(), nil
}

func validKeyID(value string) bool {
	if len(value) == 0 || len(value) > 64 {
		return false
	}
	for index, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			(index > 0 && (character == '.' || character == '_' || character == '-')) {
			continue
		}
		return false
	}
	return true
}

func validHomeName(value string) bool {
	if value == "" || len(value) > 253 || value != strings.ToLower(value) {
		return false
	}
	labels := strings.Split(value, ".")
	if len(labels) < 2 {
		return false
	}
	for _, label := range labels {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, character := range label {
			if (character >= 'a' && character <= 'z') ||
				(character >= '0' && character <= '9') || character == '-' {
				continue
			}
			return false
		}
	}
	return true
}

func requireJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("lease fields are invalid")
	}
	return nil
}

var nonDeploymentPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"),
}
