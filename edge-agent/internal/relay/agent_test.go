package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"aurora/edge-agent/internal/lease"
)

const (
	testHomeName = "home.example.net"
	testKeyID    = "home-egress-1"
)

type fakeResolver struct {
	addresses []netip.Addr
	err       error
	calls     []string
}

func (resolver *fakeResolver) LookupNetIP(_ context.Context, network, host string) ([]netip.Addr, error) {
	resolver.calls = append(resolver.calls, network+":"+host)
	return slices.Clone(resolver.addresses), resolver.err
}

type fakeRunner struct {
	calls         []string
	input         []string
	failOnApply   bool
	runtimeJSON   []byte
	runtimeReads  int
	onRuntimeRead func()
}

func (runner *fakeRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	if slices.Equal(args, []string{"-j", "list", "set", "inet", "aurora_relay", "home_ipv4"}) {
		runner.runtimeReads++
		if runner.onRuntimeRead != nil {
			runner.onRuntimeRead()
		}
		return runner.runtimeJSON, nil
	}
	runner.calls = append(runner.calls, name+" "+strings.Join(args, " "))
	if len(args) > 0 {
		raw, err := os.ReadFile(args[len(args)-1])
		if err == nil {
			runner.input = append(runner.input, string(raw))
		}
	}
	if runner.failOnApply && !slices.Contains(args, "-c") {
		return []byte("sensitive command output 8.8.4.4"), errors.New("apply failed 8.8.4.4")
	}
	return nil, nil
}

type fixture struct {
	agent      *Agent
	config     Config
	privateKey ed25519.PrivateKey
	server     *httptest.Server
	resolver   *fakeResolver
	runner     *fakeRunner
	now        time.Time
}

func newFixture(t *testing.T, sequence int64, address string) *fixture {
	t.Helper()
	seed := sha256.Sum256([]byte("aurora-relay-agent-unit-key"))
	privateKey := ed25519.NewKeyFromSeed(seed[:])
	publicKey := privateKey.Public().(ed25519.PublicKey)
	now := time.Date(2026, 7, 22, 4, 0, 0, 0, time.UTC)
	raw := signedLease(t, privateKey, sequence, address, now)
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v2/egress-lease" || request.Method != http.MethodGet ||
			request.Header.Get("x-aurora-token") != "read-secret" {
			http.Error(writer, "bad request", http.StatusUnauthorized)
			return
		}
		writer.Header().Set("content-type", "application/json")
		_, _ = writer.Write(raw)
	}))
	t.Cleanup(server.Close)
	directory := t.TempDir()
	config := Config{
		HomeName:       testHomeName,
		LeaseURL:       server.URL + "/v2/egress-lease",
		LeaseReadToken: "read-secret",
		KeyID:          testKeyID,
		PublicKey:      base64.StdEncoding.EncodeToString(publicKey),
		TailnetAddress: "100.64.0.26",
		PublicPort:     2053,
		TailnetPort:    8388,
		PollSeconds:    15,
		StatePath:      filepath.Join(directory, "state.json"),
		HostsPath:      filepath.Join(directory, "home-hosts"),
		NftPath:        filepath.Join(directory, "home-ip.nft"),
		NftBinary:      "/usr/sbin/nft",
	}
	resolver := &fakeResolver{addresses: []netip.Addr{netip.MustParseAddr(address)}}
	runtimeJSON := []byte(`{"nftables":[{"set":{"family":"inet","table":"aurora_relay","name":"home_ipv4","type":"ipv4_addr","flags":["timeout"],"elem":[{"elem":{"val":"` + address + `","timeout":7200,"expires":7100}}]}}]}`)
	runner := &fakeRunner{runtimeJSON: runtimeJSON}
	agent, err := NewAgent(config, server.Client(), resolver, runner, func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	return &fixture{
		agent: agent, config: config, privateKey: privateKey, server: server,
		resolver: resolver, runner: runner, now: now,
	}
}

func signedLease(t *testing.T, privateKey ed25519.PrivateKey, sequence int64, address string, now time.Time) []byte {
	t.Helper()
	document, err := lease.New(testKeyID, testHomeName, netip.MustParseAddr(address), sequence, now, 2*time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := lease.Sign(document, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestTickValidatesThenAtomicallyAppliesSignedTarget(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	wantCalls := []string{
		"/usr/sbin/nft -c -f " + value.runnerPath(0),
		"/usr/sbin/nft -f " + value.runnerPath(1),
	}
	if !slices.Equal(value.runner.calls, wantCalls) {
		t.Fatalf("runner calls = %#v, want %#v", value.runner.calls, wantCalls)
	}
	if len(value.resolver.calls) != 1 || value.resolver.calls[0] != "ip4:"+testHomeName {
		t.Fatalf("resolver calls = %#v", value.resolver.calls)
	}
	for _, input := range value.runner.input {
		if !strings.Contains(input, "flush set inet aurora_relay home_ipv4") ||
			!strings.Contains(input, "add element inet aurora_relay home_ipv4 { 8.8.4.4 timeout 7200s }") {
			t.Fatalf("unsafe nft transaction: %s", input)
		}
	}
	assertFile(t, value.config.HostsPath, "8.8.4.4 "+testHomeName+"\n", 0o640)
	assertFileContains(t, value.config.NftPath, "8.8.4.4", 0o640)
	assertFileContains(t, value.config.StatePath, `"sequence":10`, 0o600)
}

func (value *fixture) runnerPath(call int) string {
	parts := strings.Fields(value.runner.calls[call])
	return parts[len(parts)-1]
}

func TestTickRejectsInvalidSignatureWithoutChangingTarget(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	value.agent.publicKey[0] ^= 0xff
	if err := value.agent.Tick(context.Background()); Category(err) != "lease_invalid" {
		t.Fatalf("category = %q, err = %v", Category(err), err)
	}
	if len(value.runner.calls) != 0 || len(value.resolver.calls) != 0 {
		t.Fatalf("invalid lease reached side effects: runner=%#v resolver=%#v", value.runner.calls, value.resolver.calls)
	}
}

func TestTickRejectsReplayAndExpiredLease(t *testing.T) {
	t.Run("replay", func(t *testing.T) {
		value := newFixture(t, 9, "8.8.4.4")
		writeState(t, value.config.StatePath, 10)
		value.agent.accepted = state{Sequence: 10}
		if err := value.agent.Tick(context.Background()); Category(err) != "lease_invalid" {
			t.Fatalf("category = %q, err = %v", Category(err), err)
		}
		if len(value.runner.calls) != 0 {
			t.Fatalf("replay changed nft: %#v", value.runner.calls)
		}
	})

	t.Run("expired", func(t *testing.T) {
		value := newFixture(t, 10, "8.8.4.4")
		value.now = value.now.Add(3 * time.Hour)
		value.agent.now = func() time.Time { return value.now }
		if err := value.agent.Tick(context.Background()); Category(err) != "lease_invalid" {
			t.Fatalf("category = %q, err = %v", Category(err), err)
		}
		if len(value.runner.calls) != 0 {
			t.Fatalf("expired lease changed nft: %#v", value.runner.calls)
		}
	})
}

func TestTickRequiresDNSAndLeaseAgreement(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	value.resolver.addresses = []netip.Addr{netip.MustParseAddr("1.1.1.1")}
	if err := value.agent.Tick(context.Background()); Category(err) != "dns_lease_mismatch" {
		t.Fatalf("category = %q, err = %v", Category(err), err)
	}
	if len(value.runner.calls) != 0 {
		t.Fatalf("mismatched DNS changed nft: %#v", value.runner.calls)
	}
}

func TestCommandFailureLeavesAcceptedFilesUnchangedAndRedactsError(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	writeState(t, value.config.StatePath, 9)
	if err := os.WriteFile(value.config.HostsPath, []byte("1.1.1.1 "+testHomeName+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(value.config.NftPath, []byte("old-safe-set\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	value.agent.accepted = state{Sequence: 9}
	value.runner.failOnApply = true

	var logs bytes.Buffer
	value.agent.SetLogger(log.New(&logs, "", 0))
	err := value.agent.Tick(context.Background())
	if Category(err) != "nft_apply_failed" {
		t.Fatalf("category = %q, err = %v", Category(err), err)
	}
	if strings.Contains(err.Error(), "8.8.4.4") || strings.Contains(logs.String(), "8.8.4.4") ||
		strings.Contains(err.Error(), "sensitive command output") {
		t.Fatalf("error leaked sensitive output: err=%q logs=%q", err, logs.String())
	}
	assertFileContains(t, value.config.StatePath, `"sequence":9`, 0o600)
	assertFile(t, value.config.HostsPath, "1.1.1.1 "+testHomeName+"\n", 0o640)
	assertFile(t, value.config.NftPath, "old-safe-set\n", 0o640)
}

func TestEqualSequenceRepairsMissingRuntimeFiles(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	writeState(t, value.config.StatePath, 10)
	value.agent.accepted = state{Sequence: 10}
	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(value.runner.calls) != 2 {
		t.Fatalf("equal current lease did not repair runtime: %#v", value.runner.calls)
	}
}

func TestEqualSequenceRejectsDifferentAcceptedIdentity(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	value.agent.accepted = state{
		Sequence:  10,
		IPv4:      "1.1.1.1",
		ExpiresAt: value.now.Add(2 * time.Hour).Format(time.RFC3339),
	}
	if err := value.agent.Tick(context.Background()); Category(err) != "lease_invalid" {
		t.Fatalf("category = %q, err = %v", Category(err), err)
	}
	if len(value.runner.calls) != 0 || len(value.resolver.calls) != 0 {
		t.Fatalf("equivocated lease reached side effects: runner=%#v resolver=%#v", value.runner.calls, value.resolver.calls)
	}
}

func TestEqualLeaseAtNextPollDoesNotRewriteOrReapply(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	value.agent.now = func() time.Time { return value.now }
	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	beforeHosts, err := os.Stat(value.config.HostsPath)
	if err != nil {
		t.Fatal(err)
	}
	beforeNft, err := os.Stat(value.config.NftPath)
	if err != nil {
		t.Fatal(err)
	}
	value.runner.calls = nil
	value.runner.input = nil
	value.now = value.now.Add(15 * time.Second)

	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	afterHosts, _ := os.Stat(value.config.HostsPath)
	afterNft, _ := os.Stat(value.config.NftPath)
	if len(value.runner.calls) != 0 {
		t.Fatalf("unchanged lease reapplied nft: %#v", value.runner.calls)
	}
	if !os.SameFile(beforeHosts, afterHosts) || !os.SameFile(beforeNft, afterNft) {
		t.Fatal("unchanged lease rewrote a watched runtime file")
	}
}

func TestEqualLeaseRepairsLostKernelSetWithoutRestartingSingBox(t *testing.T) {
	for _, runtimeJSON := range []string{
		`{"nftables":[{"set":{"family":"inet","table":"aurora_relay","name":"home_ipv4","type":"ipv4_addr","flags":["timeout"]}}]}`,
		`{"nftables":[{"set":{"family":"inet","table":"aurora_relay","name":"home_ipv4","type":"ipv4_addr","flags":["timeout"],"elem":[{"elem":{"val":"1.1.1.1","expires":60000}}]}}]}`,
		`{"nftables":[{"set":{"family":"inet","table":"aurora_relay","name":"home_ipv4","type":"ipv4_addr","flags":["timeout"],"elem":[{"elem":{"val":"8.8.4.4","expires":10800}}]}}]}`,
	} {
		t.Run(runtimeJSON, func(t *testing.T) {
			value := newFixture(t, 10, "8.8.4.4")
			if err := value.agent.Tick(context.Background()); err != nil {
				t.Fatal(err)
			}
			beforeHosts, _ := os.Stat(value.config.HostsPath)
			value.runner.calls = nil
			value.runner.runtimeJSON = []byte(runtimeJSON)
			if err := value.agent.Tick(context.Background()); err != nil {
				t.Fatal(err)
			}
			if len(value.runner.calls) != 2 {
				t.Fatalf("kernel target was not repaired: %v", value.runner.calls)
			}
			afterHosts, _ := os.Stat(value.config.HostsPath)
			if !os.SameFile(beforeHosts, afterHosts) {
				t.Fatal("kernel repair rewrote watched hosts")
			}
		})
	}
}

func TestKernelReadCannotReapplyAnExpiredLease(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	value.agent.now = func() time.Time { return value.now }
	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	value.runner.calls = nil
	value.runner.runtimeJSON = []byte(`{"nftables":[]}`)
	value.runner.onRuntimeRead = func() { value.now = value.now.Add(3 * time.Hour) }
	if err := value.agent.Tick(context.Background()); Category(err) != "lease_invalid" {
		t.Fatalf("expired lease was not rejected after runtime read: %v", err)
	}
	if len(value.runner.calls) != 0 {
		t.Fatalf("expired lease reapplied: %v", value.runner.calls)
	}
}

func TestEqualLeaseRepairsOnlyTheCorruptArtifact(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}

	value.runner.calls = nil
	if err := os.WriteFile(value.config.HostsPath, []byte("corrupt\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(value.runner.calls) != 0 {
		t.Fatalf("hosts-only repair reapplied nft: %#v", value.runner.calls)
	}
	assertFile(t, value.config.HostsPath, "8.8.4.4 "+testHomeName+"\n", 0o640)

	beforeHosts, err := os.Stat(value.config.HostsPath)
	if err != nil {
		t.Fatal(err)
	}
	value.runner.calls = nil
	if err := os.WriteFile(value.config.NftPath, []byte("corrupt\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := value.agent.Tick(context.Background()); err != nil {
		t.Fatal(err)
	}
	afterHosts, _ := os.Stat(value.config.HostsPath)
	if len(value.runner.calls) != 2 {
		t.Fatalf("nft-only repair calls = %#v", value.runner.calls)
	}
	if !os.SameFile(beforeHosts, afterHosts) {
		t.Fatal("nft-only repair rewrote the watched hosts file")
	}
}

func TestConfigRejectsUnsafeValues(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	cases := map[string]func(*Config){
		"http lease":     func(config *Config) { config.LeaseURL = "http://control.example.com/v2/egress-lease" },
		"wrong path":     func(config *Config) { config.LeaseURL = "https://control.example.com/lease" },
		"reserved home":  func(config *Config) { config.HomeName = "home.example.invalid" },
		"public port":    func(config *Config) { config.PublicPort = 0 },
		"tailnet port":   func(config *Config) { config.TailnetPort = 65536 },
		"poll too short": func(config *Config) { config.PollSeconds = 1 },
		"poll too long":  func(config *Config) { config.PollSeconds = 7200 },
		"public tailnet": func(config *Config) { config.TailnetAddress = "8.8.8.8" },
		"relative path":  func(config *Config) { config.StatePath = "state.json" },
		"not nft":        func(config *Config) { config.NftBinary = "/bin/sh" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			config := value.config
			mutate(&config)
			if err := config.validate(); err == nil {
				t.Fatal("unsafe config passed")
			}
		})
	}
}

func TestConfigAcceptsNonDefaultPortsAndIntervals(t *testing.T) {
	value := newFixture(t, 10, "8.8.4.4")
	config := value.config
	config.PublicPort = 28443
	config.TailnetPort = 18388
	config.PollSeconds = 60
	config.NftBinary = "/usr/bin/nft"
	if err := config.validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
}

func assertFile(t *testing.T, path, want string, mode os.FileMode) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(raw) != want {
		t.Fatalf("%s = %q, want %q", path, raw, want)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != mode {
		t.Fatalf("%s mode = %o, want %o", path, info.Mode().Perm(), mode)
	}
}

func assertFileContains(t *testing.T, path, want string, mode os.FileMode) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), want) {
		t.Fatalf("%s = %q, missing %q", path, raw, want)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != mode {
		t.Fatalf("%s mode = %o, want %o", path, info.Mode().Perm(), mode)
	}
}

func writeState(t *testing.T, path string, sequence int64) {
	t.Helper()
	raw := []byte("{\"sequence\":" + strconv.FormatInt(sequence, 10) + "}")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}
