package relay

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// A short poll only spends Worker requests, a long one delays noticing a new home IP.
// The ceiling stays well under the lease lifetime, so an agent that is merely polling
// slowly can never let the accepted lease expire in the kernel set.
const (
	minimumPollSeconds = 5
	maximumPollSeconds = 3600
)

type Config struct {
	HomeName       string `json:"home_name"`
	LeaseURL       string `json:"lease_url"`
	LeaseReadToken string `json:"lease_read_token"`
	KeyID          string `json:"lease_key_id"`
	PublicKey      string `json:"lease_public_key_base64"`
	TailnetAddress string `json:"home_tailnet_address"`
	PublicPort     int    `json:"home_public_port"`
	TailnetPort    int    `json:"home_tailnet_port"`
	PollSeconds    int    `json:"poll_seconds"`
	StatePath      string `json:"state_path"`
	HostsPath      string `json:"hosts_path"`
	NftPath        string `json:"nft_path"`
	NftBinary      string `json:"nft_binary"`
}

func LoadConfig(path string) (Config, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return Config{}, categoryError("config_unreadable")
	}
	mode := info.Mode().Perm()
	if mode != 0o600 && mode != 0o640 {
		return Config{}, categoryError("config_permissions")
	}
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 || len(raw) > 32*1024 {
		return Config{}, categoryError("config_unreadable")
	}
	var config Config
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return Config{}, categoryError("config_invalid")
	}
	if err := requireEOF(decoder); err != nil {
		return Config{}, err
	}
	if err := config.validate(); err != nil {
		return Config{}, err
	}
	return config, nil
}

func (config Config) validate() error {
	if !validDNSName(config.HomeName) || reservedDocumentationName(config.HomeName) {
		return categoryError("config_home_name")
	}
	endpoint, err := url.Parse(config.LeaseURL)
	if err != nil || endpoint.Scheme != "https" || endpoint.Host == "" || endpoint.User != nil ||
		endpoint.Path != "/v2/egress-lease" || endpoint.RawQuery != "" || endpoint.Fragment != "" {
		return categoryError("config_lease_url")
	}
	if config.LeaseReadToken == "" || config.KeyID == "" {
		return categoryError("config_secret_missing")
	}
	publicKey, err := base64.StdEncoding.Strict().DecodeString(config.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return categoryError("config_public_key")
	}
	tailnetAddress, err := netip.ParseAddr(config.TailnetAddress)
	tailnetPrefix := netip.MustParsePrefix("100.64.0.0/10")
	if err != nil || !tailnetAddress.Is4() || tailnetAddress.String() != config.TailnetAddress ||
		!tailnetPrefix.Contains(tailnetAddress) {
		return categoryError("config_tailnet_address")
	}
	if !validPort(config.PublicPort) || !validPort(config.TailnetPort) {
		return categoryError("config_port")
	}
	if config.PollSeconds < minimumPollSeconds || config.PollSeconds > maximumPollSeconds {
		return categoryError("config_interval")
	}
	paths := []string{config.StatePath, config.HostsPath, config.NftPath, config.NftBinary}
	for _, path := range paths {
		if !filepath.IsAbs(path) {
			return categoryError("config_path")
		}
	}
	// The location of nft varies by distribution, but the agent runs this binary with
	// CAP_NET_ADMIN, so a config value must not be able to name any other program.
	if config.StatePath == config.HostsPath || config.StatePath == config.NftPath ||
		config.HostsPath == config.NftPath || filepath.Base(config.NftBinary) != "nft" {
		return categoryError("config_path")
	}
	return nil
}

func validPort(port int) bool {
	return port >= 1 && port <= 65535
}

func validDNSName(value string) bool {
	if value == "" || len(value) > 253 || value != strings.ToLower(value) || strings.HasSuffix(value, ".") {
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
			if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-' {
				continue
			}
			return false
		}
	}
	return true
}

func reservedDocumentationName(name string) bool {
	for _, suffix := range []string{"invalid", "test", "example", "localhost"} {
		if name == suffix || strings.HasSuffix(name, "."+suffix) {
			return true
		}
	}
	return false
}

func requireEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return categoryError("config_invalid")
	}
	return nil
}

type categorizedError struct {
	category string
}

func (err categorizedError) Error() string {
	return err.category
}

func categoryError(category string) error {
	return categorizedError{category: category}
}

func Category(err error) string {
	if err == nil {
		return ""
	}
	var categorized categorizedError
	if errors.As(err, &categorized) {
		return categorized.category
	}
	return "internal_error"
}
