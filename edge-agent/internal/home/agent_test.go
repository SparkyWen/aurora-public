package home

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"aurora/edge-agent/internal/lease"
)

func TestTickPublishesLeaseBeforeDNS(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	agent := fixture.Agent(t)

	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got, want := fixture.Calls(), []string{"reflector-a", "reflector-b", "lease-put", "dns-put"}; !equalStrings(got, want) {
		t.Fatalf("calls = %v, want %v", got, want)
	}
	if fixture.VerifiedLease().IPv4 != fixture.publicIPv4 {
		t.Fatal("published lease did not contain the consensus address")
	}
}

func TestTickRejectsReflectorDisagreementAndFailure(t *testing.T) {
	tests := []struct {
		name       string
		secondIPv4 string
		secondCode int
		category   string
	}{
		{name: "disagreement", secondIPv4: "8.8.4.4", secondCode: http.StatusOK, category: "reflector_disagreement"},
		{name: "failure", secondIPv4: "", secondCode: http.StatusBadGateway, category: "reflector_failed"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fixture := newHTTPFixture(t)
			defer fixture.Close()
			fixture.secondIPv4 = tc.secondIPv4
			fixture.secondCode = tc.secondCode

			err := fixture.Agent(t).Tick(context.Background())
			if Category(err) != tc.category {
				t.Fatalf("category = %q, want %q (error %v)", Category(err), tc.category, err)
			}
			for _, call := range fixture.Calls() {
				if call == "lease-put" || call == "dns-put" {
					t.Fatalf("unexpected mutation after reflector failure: %v", fixture.Calls())
				}
			}
		})
	}
}

func TestDNSFailureRetriesWithoutRepublishingLease(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	fixture.dnsCodes = []int{http.StatusBadGateway, http.StatusOK}
	agent := fixture.Agent(t)

	if err := agent.Tick(context.Background()); Category(err) != "dns_update_failed" {
		t.Fatalf("first tick error = %v", err)
	}
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatalf("second tick: %v", err)
	}
	if got, want := count(fixture.Calls(), "lease-put"), 1; got != want {
		t.Fatalf("lease PUT count = %d, want %d", got, want)
	}
	if got, want := count(fixture.Calls(), "dns-put"), 2; got != want {
		t.Fatalf("DNS PUT count = %d, want %d", got, want)
	}
}

func TestUnchangedIPRefreshesLeaseAfterFiveMinutesWithoutDNSWrite(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	agent := fixture.Agent(t)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	fixture.Advance(4 * time.Minute)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := count(fixture.Calls(), "lease-put"); got != 1 {
		t.Fatalf("lease refreshed early: %d PUTs", got)
	}

	fixture.Advance(time.Minute)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := count(fixture.Calls(), "lease-put"); got != 2 {
		t.Fatalf("lease PUT count = %d, want 2", got)
	}
	if got := count(fixture.Calls(), "dns-put"); got != 1 {
		t.Fatalf("unchanged DNS was rewritten: %d PUTs", got)
	}
}

func TestDNSRateLimitBacksOffWithoutLeakingResponse(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	fixture.dnsCodes = []int{http.StatusTooManyRequests, http.StatusOK}
	fixture.dnsErrorBody = "private-token-and-ip-response"
	agent := fixture.Agent(t)

	err := agent.Tick(context.Background())
	if Category(err) != "dns_rate_limited" || strings.Contains(err.Error(), fixture.dnsErrorBody) {
		t.Fatalf("unsafe rate-limit error: %v", err)
	}
	fixture.Advance(30 * time.Second)
	if err := agent.Tick(context.Background()); Category(err) != "dns_backoff" {
		t.Fatalf("backoff tick = %v", err)
	}
	if got := count(fixture.Calls(), "dns-put"); got != 1 {
		t.Fatalf("DNS called during backoff: %d", got)
	}
	fixture.Advance(31 * time.Second)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatalf("post-backoff tick: %v", err)
	}
	if got := count(fixture.Calls(), "dns-put"); got != 2 {
		t.Fatalf("DNS retry count = %d, want 2", got)
	}
}

func TestSequenceRemainsMonotonicWhenPersistedValueExceedsClock(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	futureSequence := fixture.Now().UnixMilli() + 10_000
	writeState(t, fixture.config.StatePath, State{
		Sequence:         futureSequence,
		LeaseIPv4:        fixture.publicIPv4,
		DNSIPv4:          fixture.publicIPv4,
		LeasePublishedAt: fixture.Now().Add(-10 * time.Minute),
	})
	agent := fixture.Agent(t)

	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := fixture.VerifiedLease().Sequence; got != futureSequence+1 {
		t.Fatalf("sequence = %d, want %d", got, futureSequence+1)
	}
}

func TestCloudflareResponseIdentityMustMatchPinnedRecord(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	fixture.responseRecordID = "different-record"
	agent := fixture.Agent(t)

	err := agent.Tick(context.Background())
	if Category(err) != "dns_identity_mismatch" {
		t.Fatalf("error = %v", err)
	}
}

func TestCheckIsReadOnlyAndValidatesDNSIdentity(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	agent := fixture.Agent(t)

	if err := agent.Check(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got, want := fixture.Calls(), []string{"reflector-a", "reflector-b", "dns-get"}; !equalStrings(got, want) {
		t.Fatalf("calls = %v, want %v", got, want)
	}
	if count(fixture.Calls(), "lease-put") != 0 || count(fixture.Calls(), "dns-put") != 0 {
		t.Fatalf("check mutated remote state: %v", fixture.Calls())
	}
}

func TestCheckAcceptsCloudflareResponseWithoutZoneID(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	fixture.omitResponseZoneID = true
	agent := fixture.Agent(t)

	if err := agent.Check(context.Background()); err != nil {
		t.Fatalf("current Cloudflare response was rejected: %v", err)
	}
}

func TestCheckRejectsMismatchedZoneIDWhenCloudflareReturnsIt(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	fixture.responseZoneID = "different-zone"
	agent := fixture.Agent(t)

	if err := agent.Check(context.Background()); Category(err) != "dns_identity_mismatch" {
		t.Fatalf("error = %v", err)
	}
}

func TestTickReconcilesDNSDriftAfterSuccessfulSync(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	agent := fixture.Agent(t)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	fixture.responseIPv4 = "8.8.4.4"
	fixture.mu.Unlock()
	fixture.Advance(5 * time.Minute)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := count(fixture.Calls(), "dns-put"); got != 2 {
		t.Fatalf("stale remote DNS was not repaired: PUT count = %d", got)
	}
}

func TestTickReconcilesDNSDriftAfterRestart(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	if err := fixture.Agent(t).Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	fixture.responseIPv4 = "8.8.4.4"
	fixture.mu.Unlock()
	if err := fixture.Agent(t).Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := count(fixture.Calls(), "dns-put"); got != 2 {
		t.Fatalf("persisted DNS state masked remote drift: PUT count = %d", got)
	}
}

func TestTickDoesNotRepairAnUnpinnedDNSRecord(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	agent := fixture.Agent(t)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	fixture.mu.Lock()
	fixture.responseRecordID = "other-record"
	fixture.mu.Unlock()
	fixture.Advance(5 * time.Minute)
	if err := agent.Tick(context.Background()); Category(err) != "dns_identity_mismatch" {
		t.Fatalf("unpinned DNS identity was not rejected: %v", err)
	}
	if got := count(fixture.Calls(), "dns-put"); got != 1 {
		t.Fatalf("wrote an unpinned record: PUT count = %d", got)
	}
}

func TestCheckAllowsAStaleButValidDNSAddressSoAgentCanRepairIt(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	fixture.responseIPv4 = "8.8.4.4"
	agent := fixture.Agent(t)

	if err := agent.Check(context.Background()); err != nil {
		t.Fatalf("stale DNS blocked repair startup: %v", err)
	}
}

func TestLoadConfigRequiresModeHTTPSAndDedicatedName(t *testing.T) {
	directory := t.TempDir()
	config := Config{
		HomeName:        "home.example.com",
		ZoneName:        "example.com",
		ZoneID:          "zone-id",
		RecordID:        "record-id",
		DNSAPIToken:     "dns-token",
		LeaseURL:        "https://cp.example.com/v2/egress-lease",
		LeaseWriteToken: "lease-token",
		KeyID:           "home-egress-1",
		PrivateKeyPath:  filepath.Join(directory, "lease.pem"),
		StatePath:       filepath.Join(directory, "state.json"),
		Reflectors:      []string{"https://one.example.com/ip", "https://two.example.com/ip"},
		PollSeconds:     20,
		RefreshSeconds:  300,
		DNSTTLSeconds:   60,
	}
	path := filepath.Join(directory, "home-agent.json")
	writeConfig(t, path, config, 0o644)
	if _, err := LoadConfig(path); Category(err) != "config_permissions" {
		t.Fatalf("mode error = %v", err)
	}

	writeConfig(t, path, config, 0o600)
	if _, err := LoadConfig(path); err != nil {
		t.Fatalf("valid config: %v", err)
	}

	config.LeaseURL = "http://cp.example.com/v2/egress-lease"
	writeConfig(t, path, config, 0o600)
	if _, err := LoadConfig(path); Category(err) != "config_https_required" {
		t.Fatalf("HTTP error = %v", err)
	}

	config.LeaseURL = "https://cp.example.com/v2/egress-lease"
	config.HomeName = config.ZoneName
	writeConfig(t, path, config, 0o600)
	if _, err := LoadConfig(path); Category(err) != "config_home_name" {
		t.Fatalf("apex error = %v", err)
	}

	config.HomeName = "home.example.invalid"
	config.ZoneName = "example.invalid"
	writeConfig(t, path, config, 0o600)
	if _, err := LoadConfig(path); Category(err) != "config_home_name" {
		t.Fatalf("documentation-zone error = %v", err)
	}

	config.HomeName = "home.example.com"
	config.ZoneName = "example.com"
	config.LeaseURL = "https://cp.example.com/lease"
	writeConfig(t, path, config, 0o600)
	if _, err := LoadConfig(path); Category(err) != "config_lease_url" {
		t.Fatalf("lease-path error = %v", err)
	}
}

func TestConfigIntervalsAreConfigurableWithinTheLeaseLifetime(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	valid := fixture.config
	valid.PollSeconds = 60
	valid.RefreshSeconds = 900
	if err := valid.validate(); err != nil {
		t.Fatalf("valid intervals rejected: %v", err)
	}
	for name, mutate := range map[string]func(*Config){
		"poll too short":       func(config *Config) { config.PollSeconds = 1 },
		"refresh under poll":   func(config *Config) { config.PollSeconds, config.RefreshSeconds = 60, 30 },
		"refresh near expiry":  func(config *Config) { config.RefreshSeconds = int(leaseValidity / time.Second) },
		"refresh not provided": func(config *Config) { config.RefreshSeconds = 0 },
	} {
		t.Run(name, func(t *testing.T) {
			config := valid
			mutate(&config)
			if Category(config.validate()) != "config_interval" {
				t.Fatalf("intervals accepted: poll=%d refresh=%d", config.PollSeconds, config.RefreshSeconds)
			}
		})
	}
}

func TestLeaseRefreshFollowsTheConfiguredInterval(t *testing.T) {
	fixture := newHTTPFixture(t)
	defer fixture.Close()
	fixture.config.RefreshSeconds = 900
	agent := fixture.Agent(t)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	fixture.Advance(14 * time.Minute)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := count(fixture.Calls(), "lease-put"); got != 1 {
		t.Fatalf("lease refreshed early: %d PUTs", got)
	}

	fixture.Advance(time.Minute)
	if err := agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := count(fixture.Calls(), "lease-put"); got != 2 {
		t.Fatalf("lease PUT count = %d, want 2", got)
	}
}

type httpFixture struct {
	t                  *testing.T
	server             *httptest.Server
	client             *http.Client
	config             Config
	privateKey         ed25519.PrivateKey
	publicKey          ed25519.PublicKey
	publicIPv4         string
	secondIPv4         string
	secondCode         int
	dnsCodes           []int
	dnsErrorBody       string
	responseRecordID   string
	responseZoneID     string
	omitResponseZoneID bool
	responseIPv4       string
	mu                 sync.Mutex
	calls              []string
	leaseRaw           []byte
	now                time.Time
}

func newHTTPFixture(t *testing.T) *httpFixture {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for index := range seed {
		seed[index] = byte(index + 1)
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	fixture := &httpFixture{
		t:                t,
		privateKey:       privateKey,
		publicKey:        privateKey.Public().(ed25519.PublicKey),
		publicIPv4:       "8.8.8.8",
		secondIPv4:       "8.8.8.8",
		secondCode:       http.StatusOK,
		dnsCodes:         []int{http.StatusOK},
		responseRecordID: "record-id",
		responseZoneID:   "zone-id",
		responseIPv4:     "8.8.8.8",
		now:              time.Date(2026, 7, 22, 1, 0, 0, 0, time.UTC),
	}
	fixture.server = httptest.NewTLSServer(http.HandlerFunc(fixture.handle))
	fixture.client = fixture.server.Client()
	fixture.config = Config{
		HomeName:        "home.example.com",
		ZoneName:        "example.com",
		ZoneID:          "zone-id",
		RecordID:        "record-id",
		DNSAPIToken:     "dns-api-test-token",
		LeaseURL:        fixture.server.URL + "/v2/egress-lease",
		LeaseWriteToken: "lease-write-test-token",
		KeyID:           "home-egress-1",
		PrivateKeyPath:  filepath.Join(t.TempDir(), "unused.pem"),
		StatePath:       filepath.Join(t.TempDir(), "state.json"),
		Reflectors:      []string{fixture.server.URL + "/reflector-a", fixture.server.URL + "/reflector-b"},
		PollSeconds:     20,
		RefreshSeconds:  300,
		DNSTTLSeconds:   60,
	}
	return fixture
}

func (fixture *httpFixture) Agent(t *testing.T) *Agent {
	t.Helper()
	agent, err := NewAgent(fixture.config, fixture.privateKey, fixture.client, fixture.Now)
	if err != nil {
		t.Fatal(err)
	}
	agent.dnsAPIBase = fixture.server.URL
	agent.logger = log.New(io.Discard, "", 0)
	return agent
}

func (fixture *httpFixture) Close() {
	fixture.server.Close()
}

func (fixture *httpFixture) Now() time.Time {
	fixture.mu.Lock()
	defer fixture.mu.Unlock()
	return fixture.now
}

func (fixture *httpFixture) Advance(duration time.Duration) {
	fixture.mu.Lock()
	fixture.now = fixture.now.Add(duration)
	fixture.mu.Unlock()
}

func (fixture *httpFixture) Calls() []string {
	fixture.mu.Lock()
	defer fixture.mu.Unlock()
	return append([]string(nil), fixture.calls...)
}

func (fixture *httpFixture) VerifiedLease() lease.Document {
	fixture.mu.Lock()
	raw := append([]byte(nil), fixture.leaseRaw...)
	now := fixture.now
	fixture.mu.Unlock()
	document, err := lease.ParseAndVerify(
		raw,
		fixture.publicKey,
		fixture.config.KeyID,
		fixture.config.HomeName,
		0,
		now,
	)
	if err != nil {
		fixture.t.Fatal(err)
	}
	return document
}

func (fixture *httpFixture) handle(writer http.ResponseWriter, request *http.Request) {
	fixture.mu.Lock()
	defer fixture.mu.Unlock()
	switch request.URL.Path {
	case "/reflector-a":
		fixture.calls = append(fixture.calls, "reflector-a")
		fmt.Fprint(writer, fixture.publicIPv4)
	case "/reflector-b":
		fixture.calls = append(fixture.calls, "reflector-b")
		writer.WriteHeader(fixture.secondCode)
		fmt.Fprint(writer, fixture.secondIPv4)
	case "/v2/egress-lease":
		fixture.calls = append(fixture.calls, "lease-put")
		if request.Method != http.MethodPut || request.Header.Get("x-aurora-lease-token") != fixture.config.LeaseWriteToken {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		fixture.leaseRaw, _ = io.ReadAll(request.Body)
		writer.WriteHeader(http.StatusNoContent)
	case "/zones/zone-id/dns_records/record-id":
		if request.Method == http.MethodGet {
			fixture.calls = append(fixture.calls, "dns-get")
			result := map[string]any{
				"id":      fixture.responseRecordID,
				"type":    "A",
				"name":    fixture.config.HomeName,
				"content": fixture.responseIPv4,
				"proxied": false,
			}
			if !fixture.omitResponseZoneID {
				result["zone_id"] = fixture.responseZoneID
			}
			_ = json.NewEncoder(writer).Encode(map[string]any{
				"success": true,
				"result":  result,
			})
			return
		}
		fixture.calls = append(fixture.calls, "dns-put")
		if request.Method != http.MethodPut || request.Header.Get("authorization") != "Bearer "+fixture.config.DNSAPIToken {
			writer.WriteHeader(http.StatusUnauthorized)
			return
		}
		code := fixture.dnsCodes[0]
		if len(fixture.dnsCodes) > 1 {
			fixture.dnsCodes = fixture.dnsCodes[1:]
		}
		if code == http.StatusTooManyRequests {
			writer.Header().Set("Retry-After", "60")
		}
		writer.WriteHeader(code)
		if code != http.StatusOK {
			fmt.Fprint(writer, fixture.dnsErrorBody)
			return
		}
		result := map[string]any{
			"id":      fixture.responseRecordID,
			"type":    "A",
			"name":    fixture.config.HomeName,
			"content": fixture.publicIPv4,
			"proxied": false,
		}
		if !fixture.omitResponseZoneID {
			result["zone_id"] = fixture.responseZoneID
		}
		_ = json.NewEncoder(writer).Encode(map[string]any{
			"success": true,
			"result":  result,
		})
	default:
		writer.WriteHeader(http.StatusNotFound)
	}
}

func writeConfig(t *testing.T, path string, config Config, mode os.FileMode) {
	t.Helper()
	raw, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func writeState(t *testing.T, path string, state State) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func count(values []string, target string) int {
	total := 0
	for _, value := range values {
		if value == target {
			total++
		}
	}
	return total
}
