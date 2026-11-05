// These tests run the unchanged core/go.mod-pinned sing-box implementation.
// Only outbound network I/O is controlled: no TUN, credentials or public network.
package upstreamdns_test

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	stdlog "log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	mdns "github.com/miekg/dns"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/adapter/outbound"
	"github.com/sagernet/sing-box/common/urltest"
	boxdns "github.com/sagernet/sing-box/dns"
	httpsdns "github.com/sagernet/sing-box/dns/transport"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing-box/protocol/group"
	sjson "github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

// The property the whole tunnel leans on right after every (re)start: every
// app on the device re-resolves at once, and all of those cache misses must
// share ONE verified DoH connection instead of each paying its own TLS
// handshake across client→relay→home→1.1.1.1. With `Connection: close` each miss opened its own socket — and, because the default
// multiplex only reuses idle sessions, its own home session and its own
// handshake to the relay entry. That turned the watchdog's first post-start
// probe into a DNS timeout in 3 of 8 cold starts, against 0 of 8 with this
// reuse. See docs/reliability-notes.md.
func TestDNSReusesOneTLSConnectionAcrossQuestions(t *testing.T) {
	for _, fixture := range []string{"expected-smart.json", "expected-global.json"} {
		t.Run(fixture, func(t *testing.T) {
			h := newHarness(t, fixture, "selector")
			h.old.unblock()
			const questions = 20
			errs := make(chan error, questions)
			for i := 0; i < questions; i++ {
				go func(i int) { errs <- h.query(context.Background(), fmt.Sprintf("q%d.example.", i)) }(i)
			}
			for i := 0; i < questions; i++ {
				if err := <-errs; err != nil {
					t.Fatal(err)
				}
			}
			if dials := h.old.dials.Load(); dials != 1 {
				t.Fatalf("%d cache misses opened %d DoH connections; they must share one", questions, dials)
			}
			if h.http2Queries.Load() != questions {
				t.Fatalf("expected %d verified HTTP/2 DNS requests, got %d", questions, h.http2Queries.Load())
			}
			// Answer caching stays on: a repeated question costs nothing.
			if err := h.query(context.Background(), "q0.example."); err != nil {
				t.Fatal(err)
			}
			if h.http2Queries.Load() != questions {
				t.Fatal("cached DNS answer was fetched again")
			}
		})
	}
}

// The price of that reuse, and its bound. A dial that was already under way
// when the group changed finishes after the group's interrupt and is pooled
// on the previous node (an upstream race: the interrupt group only learns of a
// connection once its dial returns). That socket is, by construction, one the
// previous node just carried successfully — and it lives only until the NEXT
// group change, because a group closes every internal connection it carries
// on each change regardless of interrupt_exist_connections.
func TestLateDNSSocketIsRetiredByNextGroupChange(t *testing.T) {
	for _, election := range []string{"selector", "urltest"} {
		t.Run(election, func(t *testing.T) {
			h := newHarness(t, "expected-global.json", election)
			owner := h.beginQuery("owner.example.")
			h.awaitOldDial(t)
			h.selectFresh(t)
			// The old socket becomes established AFTER the group's interrupt.
			h.old.unblock()
			if err := <-owner; err != nil {
				t.Fatal(err)
			}
			if err := h.query(context.Background(), "late.example."); err != nil {
				t.Fatal(err)
			}
			if h.fresh.dials.Load() != 0 {
				t.Fatal("the late socket was not reused: either dns-proxy retires sockets again (Connection: close is back?) or upstream changed — revisit this test and docs/reliability-notes.md")
			}
			// The very next change retires it: the following question dials the
			// node elected at that point, never the late socket.
			h.selectOld(t)
			if err := h.query(context.Background(), "after-change.example."); err != nil {
				t.Fatal(err)
			}
			if h.old.dials.Load() != 2 {
				t.Fatalf("late socket outlived the next group change (old dials=%d, want a fresh one)", h.old.dials.Load())
			}
			h.selectFresh(t)
			if err := h.query(context.Background(), "after-second-change.example."); err != nil {
				t.Fatal(err)
			}
			if h.fresh.dials.Load() != 1 {
				t.Fatalf("question after switching to fresh did not dial it (fresh dials=%d)", h.fresh.dials.Load())
			}
		})
	}
}

// The other half of the bound. A dial stuck on a node that has just died is
// shared by the questions asked while it is pending, so they wait — but only
// until that dial's own DNS deadline (10s in production, 3s here). After it,
// the next question dials the node the selector points at now.
func TestStuckOldDialDelaysNewQuestionsOnlyUntilItsDeadline(t *testing.T) {
	h := newHarness(t, "expected-global.json", "selector")
	owner := h.beginQuery("owner.example.")
	h.awaitOldDial(t)
	h.selectFresh(t)
	started := time.Now()
	during := h.beginQuery("during-stuck-dial.example.")
	select {
	case <-during:
	case <-time.After(h.timeout + time.Second):
		t.Fatalf("a question waited more than %v on a stuck dial; the bound is the DNS deadline (%v)", time.Since(started), h.timeout)
	}
	select {
	case err := <-owner:
		if err == nil {
			t.Fatal("the stuck dial's own question cannot have succeeded")
		}
	case <-time.After(h.timeout + time.Second):
		t.Fatal("the stuck dial outlived its own DNS deadline")
	}
	if err := h.query(context.Background(), "after-deadline.example."); err != nil {
		t.Fatalf("DNS did not recover on the current node after the stuck dial expired: %v", err)
	}
	if h.fresh.dials.Load() == 0 {
		t.Fatal("recovery did not use the node the selector points at")
	}
}

// The third cost of one shared connection: if it silently stops answering —
// no group change, no network change, no health-check ping upstream — every
// question fails until the first one's own DNS deadline, at which point the
// transport resets and the next question dials again. With per-question
// sockets a stalled socket only took its own question down.
func TestStalledSharedDNSConnectionRecoversAfterOneDeadline(t *testing.T) {
	h := newHarness(t, "expected-global.json", "selector")
	h.old.unblock()
	if err := h.query(context.Background(), "before-stall.example."); err != nil {
		t.Fatal(err)
	}
	h.stall.Store(true)
	started := time.Now()
	stalled := h.beginQuery("during-stall.example.")
	select {
	case err := <-stalled:
		if err == nil {
			t.Fatal("a question on the stalled connection cannot have been answered")
		}
	case <-time.After(h.timeout + time.Second):
		t.Fatalf("a stalled shared connection blocked a question for more than %v", time.Since(started))
	}
	h.stall.Store(false)
	if err := h.query(context.Background(), "after-stall.example."); err != nil {
		t.Fatalf("DNS did not recover after the stalled connection's deadline: %v", err)
	}
	if h.old.dials.Load() != 2 {
		t.Fatalf("recovery reused the stalled connection (dials=%d)", h.old.dials.Load())
	}
}

func TestDNSCertificateVerificationRemainsEnabled(t *testing.T) {
	h := newHarness(t, "expected-global.json", "selector")
	h.old.unblock()
	// The local certificate is trusted, but only for its matching identity.
	h.options.TLS.ServerName = "not-in-server-certificate.invalid"
	bad, err := httpsdns.NewHTTPS(h.ctx, log.NewNOPFactory().Logger(), "bad-cert", h.options)
	if err != nil {
		t.Fatal(err)
	}
	defer bad.Close()
	q := new(mdns.Msg)
	q.SetQuestion("identity.example.", mdns.TypeA)
	_, err = h.client.Exchange(context.Background(), bad, q, adapter.DNSQueryOptions{}, nil)
	var hostnameError x509.HostnameError
	if !errors.As(err, &hostnameError) {
		t.Fatalf("expected TLS hostname verification failure, got %v", err)
	}
}

type testManager struct {
	adapter.OutboundManager
	nodes map[string]adapter.Outbound
}

func (m *testManager) Outbound(tag string) (adapter.Outbound, bool) {
	v, ok := m.nodes[tag]
	return v, ok
}

type controlledOutbound struct {
	outbound.Adapter
	address     string
	entered     chan struct{}
	release     chan struct{}
	once        sync.Once
	releaseOnce sync.Once
	dials       atomic.Int32
}

func (o *controlledOutbound) unblock() {
	if o.release != nil {
		o.releaseOnce.Do(func() { close(o.release) })
	}
}

func (o *controlledOutbound) DialContext(ctx context.Context, network string, _ M.Socksaddr) (net.Conn, error) {
	o.dials.Add(1)
	if o.entered != nil {
		o.once.Do(func() { close(o.entered) })
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-o.release:
		}
	}
	return (&net.Dialer{}).DialContext(ctx, network, o.address)
}

func (*controlledOutbound) ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error) {
	return nil, fmt.Errorf("UDP is outside this DNS HTTPS fixture")
}

type harness struct {
	ctx          context.Context
	client       *boxdns.Client
	transport    adapter.DNSTransport
	options      option.RemoteHTTPSDNSServerOptions
	old, fresh   *controlledOutbound
	selector     *group.Selector
	urltest      *group.URLTest
	history      *urltest.HistoryStorage
	http2Queries atomic.Int32
	timeout      time.Duration
	// While set, the DoH server accepts questions and never answers them.
	stall atomic.Bool
}

func newHarness(t *testing.T, fixture, election string) *harness {
	t.Helper()
	h := &harness{ctx: service.ContextWithDefaultRegistry(context.Background())}
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if h.stall.Load() {
			<-r.Context().Done()
			return
		}
		if r.ProtoMajor == 2 {
			h.http2Queries.Add(1)
		}
		data, err := io.ReadAll(io.LimitReader(r.Body, 65536))
		if err != nil {
			t.Error(err)
			return
		}
		q := new(mdns.Msg)
		if err = q.Unpack(data); err != nil {
			t.Error(err)
			return
		}
		a := new(mdns.Msg)
		a.SetReply(q)
		a.Answer = []mdns.RR{&mdns.A{Hdr: mdns.RR_Header{Name: q.Question[0].Name, Rrtype: mdns.TypeA, Class: mdns.ClassINET, Ttl: 60}, A: net.IPv4(192, 0, 2, 2)}}
		data, err = a.Pack()
		if err != nil {
			t.Error(err)
			return
		}
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(data)
	}))
	srv.Config.ErrorLog = stdlog.New(io.Discard, "", 0)
	srv.EnableHTTP2 = true
	srv.StartTLS()
	t.Cleanup(srv.Close)
	h.old = &controlledOutbound{Adapter: outbound.NewAdapter("fixture", "old", []string{"tcp"}, nil), address: srv.Listener.Addr().String(), entered: make(chan struct{}), release: make(chan struct{})}
	h.fresh = &controlledOutbound{Adapter: outbound.NewAdapter("fixture", "fresh", []string{"tcp"}, nil), address: srv.Listener.Addr().String()}
	manager := &testManager{nodes: map[string]adapter.Outbound{"old": h.old, "fresh": h.fresh}}
	service.MustRegister[adapter.OutboundManager](h.ctx, manager)
	logger := log.NewNOPFactory().Logger()
	members, selected := []string{"old", "fresh"}, "old"
	if election == "urltest" {
		h.history = urltest.NewHistoryStorage()
		service.MustRegisterPtr(h.ctx, h.history)
		h.setDelays(10, 2000)
		u, err := group.NewURLTest(h.ctx, nil, logger, "auto", option.URLTestOutboundOptions{Outbounds: members})
		if err != nil {
			t.Fatal(err)
		}
		h.urltest = u.(*group.URLTest)
		if err := h.urltest.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = h.urltest.Close() })
		// Fresh histories drive the real election without issuing URL-test I/O.
		if _, err := h.urltest.URLTest(h.ctx); err != nil {
			t.Fatal(err)
		}
		if h.urltest.Now() != "old" {
			t.Fatal("initial URL-test election failed")
		}
		manager.nodes["auto"] = h.urltest
		members, selected = []string{"auto"}, "auto"
	}
	s, err := group.NewSelector(h.ctx, nil, logger, "proxy", option.SelectorOutboundOptions{Outbounds: members, Default: selected, InterruptExistConnections: true})
	if err != nil {
		t.Fatal(err)
	}
	h.selector = s.(*group.Selector)
	if err = h.selector.Start(); err != nil {
		t.Fatal(err)
	}
	manager.nodes["proxy"] = h.selector

	// Read the compiler's golden output, so these tests exercise exactly the
	// dns-proxy options the clients ship with.
	_, source, _, _ := runtime.Caller(0)
	data, err := os.ReadFile(filepath.Join(filepath.Dir(source), "../../app/test/fixtures", fixture))
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		DNS struct {
			Servers []map[string]any `json:"servers"`
		} `json:"dns"`
	}
	if err = json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	var options map[string]any
	for _, server := range config.DNS.Servers {
		if server["tag"] == "dns-proxy" {
			options = server
			break
		}
	}
	if options == nil {
		t.Fatal("dns-proxy missing from compiler fixture")
	}
	delete(options, "tag")
	delete(options, "type")
	address := M.ParseSocksaddr(srv.Listener.Addr().String())
	options["server"], options["server_port"] = address.Addr.String(), address.Port
	cert := string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: srv.Certificate().Raw}))
	options["tls"] = map[string]any{"server_name": "example.com", "certificate": []string{cert}}
	data, err = json.Marshal(options)
	if err != nil {
		t.Fatal(err)
	}
	if err = sjson.UnmarshalContext(h.ctx, data, &h.options); err != nil {
		t.Fatal(err)
	}
	h.transport, err = httpsdns.NewHTTPS(h.ctx, logger, "dns-proxy", h.options)
	if err != nil {
		t.Fatal(err)
	}
	if err = h.transport.Start(adapter.StartStateStart); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.old.unblock(); _ = h.transport.Close() })
	// Shorter only in this isolated fixture; the production default remains 10s.
	h.timeout = 3 * time.Second
	h.client = boxdns.NewClient(boxdns.ClientOptions{Timeout: h.timeout, Logger: logger})
	return h
}

func (h *harness) setDelays(old, fresh uint16) {
	h.history.StoreURLTestHistory("old", &adapter.URLTestHistory{Time: time.Now(), Delay: old})
	h.history.StoreURLTestHistory("fresh", &adapter.URLTestHistory{Time: time.Now(), Delay: fresh})
}

func (h *harness) selectFresh(t *testing.T) {
	t.Helper()
	if h.urltest != nil {
		h.setDelays(2000, 10)
		if _, err := h.urltest.URLTest(h.ctx); err != nil {
			t.Fatal(err)
		}
		if h.urltest.Now() != "fresh" {
			t.Fatal("URL-test member did not change")
		}
	} else if !h.selector.SelectOutbound("fresh") {
		t.Fatal("selector rejected fresh node")
	}
}

func (h *harness) selectOld(t *testing.T) {
	t.Helper()
	if h.urltest != nil {
		h.setDelays(10, 2000)
		if _, err := h.urltest.URLTest(h.ctx); err != nil {
			t.Fatal(err)
		}
		if h.urltest.Now() != "old" {
			t.Fatal("URL-test member did not change back")
		}
	} else if !h.selector.SelectOutbound("old") {
		t.Fatal("selector rejected old node")
	}
}

func (h *harness) awaitOldDial(t *testing.T) {
	t.Helper()
	select {
	case <-h.old.entered:
	case <-time.After(time.Second):
		t.Fatal("old dial never started")
	}
}

func (h *harness) beginQuery(name string) <-chan error {
	done := make(chan error, 1)
	go func() { done <- h.query(context.Background(), name) }()
	return done
}

func (h *harness) query(ctx context.Context, name string) error {
	q := new(mdns.Msg)
	q.SetQuestion(name, mdns.TypeA)
	answer, err := h.client.Exchange(ctx, h.transport, q, adapter.DNSQueryOptions{}, nil)
	if err != nil {
		return err
	}
	if len(answer.Answer) != 1 {
		return fmt.Errorf("expected one DNS answer, got %d", len(answer.Answer))
	}
	return nil
}
