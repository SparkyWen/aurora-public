package home

import (
	"bytes"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"aurora/edge-agent/internal/lease"
)

// Each poll asks both reflectors, so a short poll only costs requests and a long one
// delays noticing a new home IP. The refresh ceiling is half of the lease lifetime
// (leaseValidity in agent.go): a lease must be replaced well before it expires, or the
// relay and the app fail closed while the home node is perfectly healthy.
const (
	minimumPollSeconds    = 5
	maximumRefreshSeconds = 3600
)

type Config struct {
	HomeName        string   `json:"home_name"`
	ZoneName        string   `json:"zone_name"`
	ZoneID          string   `json:"cloudflare_zone_id"`
	RecordID        string   `json:"cloudflare_record_id"`
	DNSAPIToken     string   `json:"cloudflare_dns_api_token"`
	LeaseURL        string   `json:"lease_url"`
	LeaseWriteToken string   `json:"lease_write_token"`
	KeyID           string   `json:"lease_key_id"`
	PrivateKeyPath  string   `json:"private_key_path"`
	StatePath       string   `json:"state_path"`
	Reflectors      []string `json:"reflectors"`
	PollSeconds     int      `json:"poll_seconds"`
	RefreshSeconds  int      `json:"refresh_seconds"`
	DNSTTLSeconds   int      `json:"dns_ttl_seconds"`
}

func LoadConfig(path string) (Config, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return Config{}, categoryError("config_unreadable")
	}
	if info.Mode().Perm() != 0o600 {
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

func LoadPrivateKey(path string) (ed25519.PrivateKey, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return nil, categoryError("private_key_unreadable")
	}
	if info.Mode().Perm() != 0o600 {
		return nil, categoryError("private_key_permissions")
	}
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) > 16*1024 {
		return nil, categoryError("private_key_unreadable")
	}
	privateKey, err := lease.ParsePrivateKeyPKCS8(raw)
	if err != nil {
		return nil, categoryError("private_key_invalid")
	}
	return privateKey, nil
}

func (config Config) validate() error {
	zone := strings.ToLower(strings.TrimSuffix(config.ZoneName, "."))
	homeName := strings.ToLower(strings.TrimSuffix(config.HomeName, "."))
	if zone == "" || homeName == "" || config.ZoneName != zone ||
		config.HomeName != homeName || homeName == zone ||
		!strings.HasSuffix(homeName, "."+zone) || reservedDocumentationZone(zone) {
		return categoryError("config_home_name")
	}
	if !validIdentifier(config.ZoneID) || !validIdentifier(config.RecordID) {
		return categoryError("config_dns_identity")
	}
	if config.DNSAPIToken == "" || config.LeaseWriteToken == "" || config.KeyID == "" {
		return categoryError("config_secret_missing")
	}
	if config.PollSeconds < minimumPollSeconds || config.RefreshSeconds < config.PollSeconds ||
		config.RefreshSeconds > maximumRefreshSeconds {
		return categoryError("config_interval")
	}
	if config.DNSTTLSeconds != 30 && config.DNSTTLSeconds != 60 {
		return categoryError("config_dns_ttl")
	}
	if len(config.Reflectors) != 2 || config.Reflectors[0] == config.Reflectors[1] {
		return categoryError("config_reflectors")
	}
	for _, endpoint := range append([]string{config.LeaseURL}, config.Reflectors...) {
		parsed, err := url.Parse(endpoint)
		if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil {
			return categoryError("config_https_required")
		}
	}
	leaseURL, _ := url.Parse(config.LeaseURL)
	if leaseURL.Path != "/v2/egress-lease" {
		return categoryError("config_lease_url")
	}
	if !filepath.IsAbs(config.PrivateKeyPath) || !filepath.IsAbs(config.StatePath) ||
		config.PrivateKeyPath == config.StatePath {
		return categoryError("config_path")
	}
	return nil
}

func reservedDocumentationZone(zone string) bool {
	for _, suffix := range []string{"invalid", "test", "example", "localhost"} {
		if zone == suffix || strings.HasSuffix(zone, "."+suffix) {
			return true
		}
	}
	return false
}

func validIdentifier(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9') ||
			character == '-' || character == '_' {
			continue
		}
		return false
	}
	return true
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

func redactedError(category string, _ error) error {
	return fmt.Errorf("%w", categoryError(category))
}
