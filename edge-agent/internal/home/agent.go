package home

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"aurora/edge-agent/internal/lease"
)

const (
	maximumSafeJSONInteger int64 = 9_007_199_254_740_991
	leaseValidity                = 2 * time.Hour
)

type State struct {
	Sequence         int64     `json:"sequence"`
	LeaseIPv4        string    `json:"lease_ipv4,omitempty"`
	DNSIPv4          string    `json:"dns_ipv4,omitempty"`
	LeasePublishedAt time.Time `json:"lease_published_at,omitempty"`
}

type Agent struct {
	config         Config
	privateKey     ed25519.PrivateKey
	client         *http.Client
	now            func() time.Time
	state          State
	dnsAPIBase     string
	nextDNSAttempt time.Time
	nextDNSCheck   time.Time
	logger         *log.Logger
}

func NewAgent(
	config Config,
	privateKey ed25519.PrivateKey,
	client *http.Client,
	now func() time.Time,
) (*Agent, error) {
	if err := config.validate(); err != nil {
		return nil, err
	}
	if len(privateKey) != ed25519.PrivateKeySize {
		return nil, categoryError("private_key_invalid")
	}
	if client == nil {
		client = &http.Client{}
	}
	if now == nil {
		now = time.Now
	}
	state, err := loadState(config.StatePath)
	if err != nil {
		return nil, err
	}
	return &Agent{
		config:     config,
		privateKey: privateKey,
		client:     client,
		now:        now,
		state:      state,
		dnsAPIBase: "https://api.cloudflare.com/client/v4",
		logger:     log.New(io.Discard, "", 0),
	}, nil
}

func (agent *Agent) Tick(ctx context.Context) error {
	address, err := agent.consensusIPv4(ctx)
	if err != nil {
		return err
	}
	now := agent.now().UTC()
	addressText := address.String()
	leaseDue := agent.state.Sequence == 0 || agent.state.LeaseIPv4 != addressText ||
		now.Sub(agent.state.LeasePublishedAt) >= time.Duration(agent.config.RefreshSeconds)*time.Second

	if leaseDue {
		if err := agent.publishLease(ctx, address, now); err != nil {
			return err
		}
	}
	if !agent.nextDNSAttempt.IsZero() && now.Before(agent.nextDNSAttempt) {
		return categoryError("dns_backoff")
	}
	if agent.state.DNSIPv4 == addressText {
		if now.Before(agent.nextDNSCheck) {
			return nil
		}
		// Persisted state records our last write, not the record Cloudflare
		// serves now. Reconcile on restart and every lease refresh interval.
		record, err := agent.readDNS(ctx)
		if err != nil {
			return err
		}
		if err := agent.validateDNSRecord(record); err != nil {
			return err
		}
		if record.Result.Content == addressText {
			agent.nextDNSCheck = now.Add(time.Duration(agent.config.RefreshSeconds) * time.Second)
			return nil
		}
	}

	retryAfter, err := agent.updateDNS(ctx, address)
	if err != nil {
		if Category(err) == "dns_rate_limited" {
			agent.nextDNSAttempt = now.Add(retryAfter)
		}
		return err
	}
	agent.nextDNSAttempt = time.Time{}
	agent.nextDNSCheck = now.Add(time.Duration(agent.config.RefreshSeconds) * time.Second)
	agent.state.DNSIPv4 = addressText
	if err := saveState(agent.config.StatePath, agent.state); err != nil {
		return err
	}
	return nil
}

func (agent *Agent) Check(ctx context.Context) error {
	address, err := agent.consensusIPv4(ctx)
	if err != nil {
		return err
	}
	return agent.checkDNS(ctx, address)
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

func (agent *Agent) consensusIPv4(ctx context.Context) (netip.Addr, error) {
	addresses := make([]netip.Addr, 0, len(agent.config.Reflectors))
	for _, endpoint := range agent.config.Reflectors {
		address, err := agent.fetchReflector(ctx, endpoint)
		if err != nil {
			return netip.Addr{}, err
		}
		addresses = append(addresses, address)
	}
	if len(addresses) != 2 || addresses[0] != addresses[1] {
		return netip.Addr{}, categoryError("reflector_disagreement")
	}
	return addresses[0], nil
}

func (agent *Agent) fetchReflector(ctx context.Context, endpoint string) (netip.Addr, error) {
	requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(requestContext, http.MethodGet, endpoint, nil)
	if err != nil {
		return netip.Addr{}, redactedError("reflector_failed", err)
	}
	response, err := agent.client.Do(request)
	if err != nil {
		return netip.Addr{}, redactedError("reflector_failed", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return netip.Addr{}, categoryError("reflector_failed")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 129))
	if err != nil || len(raw) > 128 {
		return netip.Addr{}, categoryError("reflector_failed")
	}
	address, err := netip.ParseAddr(strings.TrimSpace(string(raw)))
	if err != nil || lease.ValidateDeploymentIPv4(address) != nil {
		return netip.Addr{}, categoryError("reflector_invalid")
	}
	return address, nil
}

func (agent *Agent) publishLease(ctx context.Context, address netip.Addr, now time.Time) error {
	sequence := now.UnixMilli()
	if sequence <= agent.state.Sequence {
		sequence = agent.state.Sequence + 1
	}
	if sequence <= 0 || sequence > maximumSafeJSONInteger {
		return categoryError("sequence_invalid")
	}
	document, err := lease.New(
		agent.config.KeyID,
		agent.config.HomeName,
		address,
		sequence,
		now,
		leaseValidity,
	)
	if err != nil {
		return redactedError("lease_build_failed", err)
	}
	raw, err := lease.Sign(document, agent.privateKey)
	if err != nil {
		return redactedError("lease_sign_failed", err)
	}
	requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(
		requestContext,
		http.MethodPut,
		agent.config.LeaseURL,
		bytes.NewReader(raw),
	)
	if err != nil {
		return redactedError("lease_publish_failed", err)
	}
	request.Header.Set("content-type", "application/json")
	request.Header.Set("x-aurora-lease-token", agent.config.LeaseWriteToken)
	response, err := agent.client.Do(request)
	if err != nil {
		return redactedError("lease_publish_failed", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		return categoryError("lease_publish_failed")
	}
	agent.state.Sequence = sequence
	agent.state.LeaseIPv4 = address.String()
	agent.state.LeasePublishedAt = now
	if err := saveState(agent.config.StatePath, agent.state); err != nil {
		return err
	}
	agent.logger.Printf(
		"lease published sequence_suffix=%06d address=%s",
		sequence%1_000_000,
		lease.MaskIPv4(address.String()),
	)
	return nil
}

func loadState(path string) (State, error) {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return State{}, nil
	}
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return State{}, categoryError("state_unreadable")
	}
	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 || len(raw) > 4096 {
		return State{}, categoryError("state_unreadable")
	}
	var state State
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return State{}, categoryError("state_invalid")
	}
	if err := requireEOF(decoder); err != nil {
		return State{}, categoryError("state_invalid")
	}
	if state.Sequence < 0 || state.Sequence > maximumSafeJSONInteger {
		return State{}, categoryError("state_invalid")
	}
	for _, value := range []string{state.LeaseIPv4, state.DNSIPv4} {
		if value == "" {
			continue
		}
		address, err := netip.ParseAddr(value)
		if err != nil || lease.ValidateDeploymentIPv4(address) != nil {
			return State{}, categoryError("state_invalid")
		}
	}
	return state, nil
}

func saveState(path string, state State) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return redactedError("state_write_failed", err)
	}
	raw, err := json.Marshal(state)
	if err != nil {
		return redactedError("state_write_failed", err)
	}
	temporary, err := os.CreateTemp(directory, ".home-agent-state-*")
	if err != nil {
		return redactedError("state_write_failed", err)
	}
	temporaryPath := temporary.Name()
	cleanup := func() {
		temporary.Close()
		_ = os.Remove(temporaryPath)
	}
	if err := temporary.Chmod(0o600); err != nil {
		cleanup()
		return redactedError("state_write_failed", err)
	}
	if _, err := temporary.Write(raw); err != nil {
		cleanup()
		return redactedError("state_write_failed", err)
	}
	if err := temporary.Sync(); err != nil {
		cleanup()
		return redactedError("state_write_failed", err)
	}
	if err := temporary.Close(); err != nil {
		_ = os.Remove(temporaryPath)
		return redactedError("state_write_failed", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		_ = os.Remove(temporaryPath)
		return redactedError("state_write_failed", err)
	}
	return nil
}
