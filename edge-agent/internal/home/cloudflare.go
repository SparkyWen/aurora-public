package home

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"time"

	"aurora/edge-agent/internal/lease"
)

type cloudflareUpdate struct {
	Type    string `json:"type"`
	Name    string `json:"name"`
	Content string `json:"content"`
	TTL     int    `json:"ttl"`
	Proxied bool   `json:"proxied"`
	Comment string `json:"comment"`
}

type cloudflareResponse struct {
	Success bool `json:"success"`
	Result  struct {
		ID      string `json:"id"`
		ZoneID  string `json:"zone_id"`
		Type    string `json:"type"`
		Name    string `json:"name"`
		Content string `json:"content"`
		Proxied bool   `json:"proxied"`
	} `json:"result"`
}

func (agent *Agent) updateDNS(ctx context.Context, address netip.Addr) (time.Duration, error) {
	body, err := json.Marshal(cloudflareUpdate{
		Type:    "A",
		Name:    agent.config.HomeName,
		Content: address.String(),
		TTL:     agent.config.DNSTTLSeconds,
		Proxied: false,
		Comment: "Aurora home egress DDNS",
	})
	if err != nil {
		return 0, redactedError("dns_update_failed", err)
	}
	requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(
		requestContext,
		http.MethodPut,
		agent.dnsRecordEndpoint(),
		bytes.NewReader(body),
	)
	if err != nil {
		return 0, redactedError("dns_update_failed", err)
	}
	request.Header.Set("authorization", "Bearer "+agent.config.DNSAPIToken)
	request.Header.Set("content-type", "application/json")
	response, err := agent.client.Do(request)
	if err != nil {
		return 0, redactedError("dns_update_failed", err)
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusTooManyRequests {
		return retryAfter(response.Header.Get("retry-after")), categoryError("dns_rate_limited")
	}
	if response.StatusCode != http.StatusOK {
		return 0, categoryError("dns_update_failed")
	}
	decoded, err := decodeCloudflareResponse(response.Body)
	if err != nil {
		return 0, err
	}
	if err := agent.validateDNSIdentity(decoded, address); err != nil {
		return 0, err
	}
	agent.logger.Printf("DNS updated address=%s", leaseMask(address))
	return 0, nil
}

func (agent *Agent) checkDNS(ctx context.Context, address netip.Addr) error {
	decoded, err := agent.readDNS(ctx)
	if err != nil {
		return err
	}
	return agent.validateDNSRecord(decoded)
}

func (agent *Agent) readDNS(ctx context.Context) (cloudflareResponse, error) {
	requestContext, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(
		requestContext,
		http.MethodGet,
		agent.dnsRecordEndpoint(),
		nil,
	)
	if err != nil {
		return cloudflareResponse{}, redactedError("dns_check_failed", err)
	}
	request.Header.Set("authorization", "Bearer "+agent.config.DNSAPIToken)
	response, err := agent.client.Do(request)
	if err != nil {
		return cloudflareResponse{}, redactedError("dns_check_failed", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return cloudflareResponse{}, categoryError("dns_check_failed")
	}
	decoded, err := decodeCloudflareResponse(response.Body)
	if err != nil {
		return cloudflareResponse{}, err
	}
	return decoded, nil
}

func (agent *Agent) dnsRecordEndpoint() string {
	return strings.TrimSuffix(agent.dnsAPIBase, "/") +
		"/zones/" + agent.config.ZoneID +
		"/dns_records/" + agent.config.RecordID
}

func decodeCloudflareResponse(body io.Reader) (cloudflareResponse, error) {
	raw, err := io.ReadAll(io.LimitReader(body, 8193))
	if err != nil || len(raw) > 8192 {
		return cloudflareResponse{}, categoryError("dns_update_failed")
	}
	var decoded cloudflareResponse
	if err := json.Unmarshal(raw, &decoded); err != nil || !decoded.Success {
		return cloudflareResponse{}, categoryError("dns_update_failed")
	}
	return decoded, nil
}

func (agent *Agent) validateDNSIdentity(decoded cloudflareResponse, address netip.Addr) error {
	if err := agent.validateDNSRecord(decoded); err != nil {
		return err
	}
	if decoded.Result.Content != address.String() {
		return categoryError("dns_identity_mismatch")
	}
	return nil
}

func (agent *Agent) validateDNSRecord(decoded cloudflareResponse) error {
	address, err := netip.ParseAddr(decoded.Result.Content)
	if decoded.Result.ID != agent.config.RecordID ||
		(decoded.Result.ZoneID != "" && decoded.Result.ZoneID != agent.config.ZoneID) ||
		decoded.Result.Type != "A" ||
		decoded.Result.Name != agent.config.HomeName ||
		decoded.Result.Proxied || err != nil || lease.ValidateDeploymentIPv4(address) != nil {
		return categoryError("dns_identity_mismatch")
	}
	return nil
}

func retryAfter(value string) time.Duration {
	seconds, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || seconds < 1 {
		return 60 * time.Second
	}
	if seconds > 15*60 {
		seconds = 15 * 60
	}
	return time.Duration(seconds) * time.Second
}

func leaseMask(address netip.Addr) string {
	octets := address.As4()
	return "***.***.***." + strconv.Itoa(int(octets[3]))
}
