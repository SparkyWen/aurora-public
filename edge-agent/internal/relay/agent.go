package relay

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"aurora/edge-agent/internal/lease"
)

type Resolver interface {
	LookupNetIP(context.Context, string, string) ([]netip.Addr, error)
}

type Runner interface {
	Run(context.Context, string, ...string) ([]byte, error)
}

type state struct {
	Sequence  int64  `json:"sequence"`
	IPv4      string `json:"ipv4,omitempty"`
	ExpiresAt string `json:"expires_at,omitempty"`
}

type Agent struct {
	config    Config
	publicKey ed25519.PublicKey
	client    *http.Client
	resolver  Resolver
	runner    Runner
	now       func() time.Time
	accepted  state
	logger    *log.Logger
}

func NewAgent(
	config Config,
	client *http.Client,
	resolver Resolver,
	runner Runner,
	now func() time.Time,
) (*Agent, error) {
	if err := config.validate(); err != nil {
		return nil, err
	}
	publicKey, err := base64.StdEncoding.Strict().DecodeString(config.PublicKey)
	if err != nil || len(publicKey) != ed25519.PublicKeySize {
		return nil, categoryError("config_public_key")
	}
	if client == nil || resolver == nil || runner == nil {
		return nil, categoryError("dependency_missing")
	}
	if now == nil {
		now = time.Now
	}
	accepted, err := loadState(config.StatePath)
	if err != nil {
		return nil, err
	}
	return &Agent{
		config:    config,
		publicKey: ed25519.PublicKey(publicKey),
		client:    client,
		resolver:  resolver,
		runner:    runner,
		now:       now,
		accepted:  accepted,
		logger:    log.New(io.Discard, "", 0),
	}, nil
}

func (agent *Agent) Tick(ctx context.Context) error {
	raw, err := agent.fetchLease(ctx)
	if err != nil {
		return err
	}
	document, err := lease.ParseAndVerify(
		raw,
		agent.publicKey,
		agent.config.KeyID,
		agent.config.HomeName,
		agent.accepted.Sequence,
		agent.now().UTC(),
	)
	if err != nil {
		return categoryError("lease_invalid")
	}
	if document.Sequence == agent.accepted.Sequence &&
		(agent.accepted.IPv4 != "" || agent.accepted.ExpiresAt != "") &&
		(agent.accepted.IPv4 != document.IPv4 || agent.accepted.ExpiresAt != document.ExpiresAt) {
		return categoryError("lease_invalid")
	}
	address, err := netip.ParseAddr(document.IPv4)
	if err != nil || lease.ValidateDeploymentIPv4(address) != nil {
		return categoryError("lease_invalid")
	}
	if err := agent.requireDNSAgreement(ctx, address); err != nil {
		return err
	}

	expiresAt, err := time.Parse(time.RFC3339Nano, document.ExpiresAt)
	if err != nil {
		return categoryError("lease_invalid")
	}
	hostsDocument := []byte(address.String() + " " + agent.config.HomeName + "\n")
	accepted := state{
		Sequence:  document.Sequence,
		IPv4:      document.IPv4,
		ExpiresAt: document.ExpiresAt,
	}
	stateMatches := document.Sequence == agent.accepted.Sequence &&
		agent.accepted.IPv4 == document.IPv4 &&
		agent.accepted.ExpiresAt == document.ExpiresAt
	nftMatches := stateMatches && nftTargetMatches(agent.config.NftPath, address, 0o640)
	if nftMatches {
		nftMatches = agent.runtimeTargetMatches(ctx, address, expiresAt)
	}
	remaining := expiresAt.Sub(agent.now().UTC())
	if remaining <= 0 {
		return categoryError("lease_invalid")
	}
	nftDocument := renderNftTransaction(address, remaining)
	hostsMatches := fileMatches(agent.config.HostsPath, hostsDocument, 0o640)
	if nftMatches && hostsMatches {
		return nil
	}
	if err := agent.apply(
		ctx,
		accepted,
		nftDocument,
		hostsDocument,
		!nftMatches,
		!hostsMatches,
	); err != nil {
		return err
	}
	agent.logger.Printf(
		"target accepted sequence_suffix=%06d address=%s",
		document.Sequence%1_000_000,
		lease.MaskIPv4(document.IPv4),
	)
	return nil
}

func (agent *Agent) Run(ctx context.Context) {
	for {
		if err := agent.Tick(ctx); err != nil && !errors.Is(err, context.Canceled) {
			agent.logger.Printf("tick failed category=%s", Category(err))
		}
		timer := time.NewTimer(time.Duration(agent.config.PollSeconds) * time.Second)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
		}
	}
}

func (agent *Agent) SetLogger(logger *log.Logger) {
	if logger != nil {
		agent.logger = logger
	}
}

func (agent *Agent) fetchLease(ctx context.Context) ([]byte, error) {
	requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(requestContext, http.MethodGet, agent.config.LeaseURL, nil)
	if err != nil {
		return nil, categoryError("lease_fetch_failed")
	}
	request.Header.Set("x-aurora-token", agent.config.LeaseReadToken)
	response, err := agent.client.Do(request)
	if err != nil {
		return nil, categoryError("lease_fetch_failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, categoryError("lease_fetch_failed")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, lease.MaximumBytes+1))
	if err != nil || len(raw) == 0 || len(raw) > lease.MaximumBytes {
		return nil, categoryError("lease_fetch_failed")
	}
	return raw, nil
}

func (agent *Agent) requireDNSAgreement(ctx context.Context, signedAddress netip.Addr) error {
	resolveContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	addresses, err := agent.resolver.LookupNetIP(resolveContext, "ip4", agent.config.HomeName)
	if err != nil || len(addresses) == 0 {
		return categoryError("dns_resolve_failed")
	}
	for _, address := range addresses {
		if address == signedAddress {
			return nil
		}
	}
	return categoryError("dns_lease_mismatch")
}

func (agent *Agent) apply(
	ctx context.Context,
	accepted state,
	nftDocument, hostsDocument []byte,
	applyNft, writeHosts bool,
) error {
	var nftTemporary string
	cleanupNft := func() {}
	var hostsTemporary string
	cleanupHosts := func() {}
	var err error
	if applyNft {
		nftTemporary, cleanupNft, err = prepareAtomic(agent.config.NftPath, nftDocument, 0o640)
		if err != nil {
			return categoryError("target_write_failed")
		}
		defer cleanupNft()
	}
	if writeHosts {
		hostsTemporary, cleanupHosts, err = prepareAtomic(agent.config.HostsPath, hostsDocument, 0o640)
		if err != nil {
			return categoryError("target_write_failed")
		}
		defer cleanupHosts()
	}

	if applyNft {
		if _, err := agent.runner.Run(ctx, agent.config.NftBinary, "-c", "-f", nftTemporary); err != nil {
			return categoryError("nft_check_failed")
		}
		if _, err := agent.runner.Run(ctx, agent.config.NftBinary, "-f", nftTemporary); err != nil {
			return categoryError("nft_apply_failed")
		}
		if err := os.Rename(nftTemporary, agent.config.NftPath); err != nil {
			return categoryError("target_write_failed")
		}
	}
	if writeHosts {
		if err := os.Rename(hostsTemporary, agent.config.HostsPath); err != nil {
			return categoryError("target_write_failed")
		}
	}
	if err := saveState(agent.config.StatePath, accepted); err != nil {
		return err
	}
	agent.accepted = accepted
	return nil
}

func renderNftTransaction(address netip.Addr, lifetime time.Duration) []byte {
	seconds := int64(lifetime / time.Second)
	if lifetime%time.Second != 0 {
		seconds++
	}
	if seconds < 1 {
		seconds = 1
	}
	return []byte(
		"flush set inet aurora_relay home_ipv4\n" +
			"add element inet aurora_relay home_ipv4 { " + address.String() +
			" timeout " + strconv.FormatInt(seconds, 10) + "s }\n",
	)
}

// A matching transaction file is not evidence that the kernel still holds
// its expiring element (e.g. another firewall reload flushed the set).
// Inspect only our fixed set; an absent, malformed or unreadable set is
// repaired by the same signed single-address transaction used at bootstrap.
func (agent *Agent) runtimeTargetMatches(ctx context.Context, address netip.Addr, expiresAt time.Time) bool {
	queryContext, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	raw, err := agent.runner.Run(queryContext, agent.config.NftBinary,
		"-j", "list", "set", "inet", "aurora_relay", "home_ipv4")
	if err != nil || len(raw) > 64*1024 {
		return false
	}
	var document struct {
		Nftables []struct {
			Set *struct {
				Family string `json:"family"`
				Table  string `json:"table"`
				Name   string `json:"name"`
				Type   string `json:"type"`
				Elem   []struct {
					Elem struct {
						Val     string `json:"val"`
						Expires int64  `json:"expires"`
					} `json:"elem"`
				} `json:"elem"`
			} `json:"set"`
		} `json:"nftables"`
	}
	if json.Unmarshal(raw, &document) != nil {
		return false
	}
	for _, entry := range document.Nftables {
		set := entry.Set
		if set == nil || set.Family != "inet" || set.Table != "aurora_relay" ||
			set.Name != "home_ipv4" || set.Type != "ipv4_addr" {
			continue
		}
		if len(set.Elem) != 1 {
			return false
		}
		element := set.Elem[0].Elem
		// nft JSON reports whole seconds (src/json.c set_elem_expr_json).
		// Allow transaction rounding and the bounded query's elapsed time.
		maximum := int64(expiresAt.Sub(agent.now().UTC())/time.Second) + 3
		return element.Val == address.String() && element.Expires > 0 && element.Expires <= maximum
	}
	return false
}

func prepareAtomic(path string, content []byte, mode os.FileMode) (string, func(), error) {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o750); err != nil {
		return "", func() {}, err
	}
	temporary, err := os.CreateTemp(directory, ".aurora-relay-*")
	if err != nil {
		return "", func() {}, err
	}
	temporaryPath := temporary.Name()
	cleanup := func() {
		_ = temporary.Close()
		_ = os.Remove(temporaryPath)
	}
	if err := temporary.Chmod(mode); err != nil {
		cleanup()
		return "", func() {}, err
	}
	if _, err := temporary.Write(content); err != nil {
		cleanup()
		return "", func() {}, err
	}
	if err := temporary.Sync(); err != nil {
		cleanup()
		return "", func() {}, err
	}
	if err := temporary.Close(); err != nil {
		_ = os.Remove(temporaryPath)
		return "", func() {}, err
	}
	return temporaryPath, cleanup, nil
}

func fileMatches(path string, content []byte, mode os.FileMode) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != mode {
		return false
	}
	raw, err := os.ReadFile(path)
	return err == nil && bytes.Equal(raw, content)
}

func nftTargetMatches(path string, address netip.Addr, mode os.FileMode) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != mode {
		return false
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	fields := bytes.Fields(raw)
	if len(fields) != 15 {
		return false
	}
	want := []string{
		"flush", "set", "inet", "aurora_relay", "home_ipv4",
		"add", "element", "inet", "aurora_relay", "home_ipv4", "{",
		address.String(), "timeout",
	}
	for index, expected := range want {
		if string(fields[index]) != expected {
			return false
		}
	}
	if string(fields[14]) != "}" {
		return false
	}
	timeout := string(fields[13])
	if len(timeout) < 2 || timeout[len(timeout)-1] != 's' {
		return false
	}
	seconds, err := strconv.ParseInt(timeout[:len(timeout)-1], 10, 64)
	return err == nil && seconds > 0
}

func loadState(path string) (state, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return state{}, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return state{}, categoryError("state_unreadable")
	}
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 || len(raw) > 4096 {
		return state{}, categoryError("state_unreadable")
	}
	var accepted state
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&accepted); err != nil || requireEOF(decoder) != nil || accepted.Sequence < 0 {
		return state{}, categoryError("state_invalid")
	}
	return accepted, nil
}

func saveState(path string, accepted state) error {
	raw, err := json.Marshal(accepted)
	if err != nil {
		return categoryError("state_write_failed")
	}
	temporary, cleanup, err := prepareAtomic(path, raw, 0o600)
	if err != nil {
		return categoryError("state_write_failed")
	}
	defer cleanup()
	if err := os.Rename(temporary, path); err != nil {
		return categoryError("state_write_failed")
	}
	return nil
}
