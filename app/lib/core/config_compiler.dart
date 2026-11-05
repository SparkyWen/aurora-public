import 'dart:convert';

import 'contract.dart';
import 'tailnet_options.dart';

enum AuroraMode { smart, global }

AuroraMode auroraModeFromString(String? value) =>
    value == 'global' ? AuroraMode.global : AuroraMode.smart;

enum AuroraPlatform {
  android,
  ios,
  desktop,
  windows,
  linux;

  /// The two desktop platforms that run the official sing-box binary: the app reads
  /// state/traffic/latency and switches nodes through the Clash API instead of the
  /// libbox CommandClient.
  bool get usesClashApi =>
      this == AuroraPlatform.windows || this == AuroraPlatform.linux;

  /// Desktop platforms that capture everything through a TUN, with the core run privileged by aurora-svc.
  bool get isSvcDesktop => usesClashApi;
}

/// Fixed interface name of the desktop TUN.
///
/// Without a name sing-box allocates one (`tun0`/`tun3`/...), so there is nothing
/// to wait on for "the adapter really disappeared after stop", and the start that
/// follows immediately would fight the lingering adapter for the device. The
/// watchdog's self-heal (stop -> connect) has exactly that timing. The Go side
/// (`desktop/aurora-svc`) has a constant with the same name; both must change
/// together.
const String auroraTunInterfaceName = 'aurora0';

/// Host addresses of each platform's TUN (`_tunInbound` writes these plus the
/// prefix length into the config).
///
/// `physical_network.dart` uses them to drop the tunnel interface from the
/// "physical network" signature; dropping by name is not enough on Windows (the
/// wintun name varies per user) and Android (`tun0`). This is the only definition:
/// change an address here, or the physical-network check will mistake the
/// tunnel for a physical NIC.
const String auroraTunHostV4Mobile = '10.111.222.1';
const String auroraTunHostV4Desktop = '172.19.0.1';
const String auroraTunHostV6 = 'fdfe:dcba:9876::1';
const List<String> auroraTunHostAddresses = [
  auroraTunHostV4Mobile,
  auroraTunHostV4Desktop,
  auroraTunHostV6,
];

/// DNS server inside the TUN: the next address after the host address (libbox
/// `GetDNSServerAddress` takes `Inet4Address[0].Addr().Next()`, and it is the only
/// other address in the desktop /30). iOS and macOS use a small subnet, every other
/// platform uses 172.19.0.1/30. The watchdog queries it directly to bypass the
/// system resolver cache.
String auroraTunDnsServerV4({required bool apple}) {
  final host = (apple ? auroraTunHostV4Mobile : auroraTunHostV4Desktop)
      .split('.')
      .map(int.parse)
      .toList();
  return [...host.take(3), host[3] + 1].join('.');
}

/// Compiles an [AuroraContract] + mode + platform into a full sing-box 1.13 JSON
/// (architecture spec §5.2). The routing/DNS skeleton is baked per mode (matching
/// the VPS gold-standard `aurora-{global,smart}.json`); node outbounds + the
/// selector/urltest group are injected from the contract.
///
/// Structural gold standard: `aurora-global.json` / `aurora-smart.json`. Keep this
/// in lockstep (unit tests assert equality against sanitized fixtures).
class ConfigCompiler {
  /// Longest interval at which urltest re-evaluates its members.
  ///
  /// Contracts typically say 3m. When a leg dies mid-session (for example a carrier
  /// blocking UDP/443 to the relay, so the hy2 leg is dead on every probe), three
  /// minutes means the user stares at a spinner for three minutes. 60s is a value
  /// that is long enough not to retest the whole group on a single blip and short
  /// enough that the user has not yet restarted the app.
  static const maxUrltestInterval = Duration(seconds: 60);

  /// Tightens the contract's interval to at most [maxUrltestInterval].
  ///
  /// **Tighten only, never loosen**: the contract is signed and delivered, so the
  /// compiler has no authority to make it laxer; if the contract asks for shorter,
  /// that wins. A value that cannot be parsed is treated as the cap, because passing a
  /// string the core cannot read straight through makes sing-box reject the whole
  /// config.
  static String capUrltestInterval(String raw) {
    final parsed = _parseDuration(raw);
    if (parsed == null || parsed > maxUrltestInterval) {
      return '${maxUrltestInterval.inSeconds}s';
    }
    return raw;
  }

  /// Recognises only the suffixes sing-box uses (`s`/`m`/`h`); returns null otherwise.
  static Duration? _parseDuration(String raw) {
    final match = RegExp(r'^(\d+)(s|m|h)$').firstMatch(raw.trim());
    if (match == null) return null;
    final value = int.parse(match.group(1)!);
    return switch (match.group(2)!) {
      's' => Duration(seconds: value),
      'm' => Duration(minutes: value),
      _ => Duration(hours: value),
    };
  }

  /// [ruleSetPaths] maps a rule-set tag (geosite-cn / geoip-cn /
  /// geosite-geolocation-!cn) to the on-device absolute path of the extracted
  /// `.srs` asset (smart mode only). Empty in global mode.
  static Map<String, dynamic> compile(
    AuroraContract contract, {
    required AuroraMode mode,
    required AuroraPlatform platform,
    Map<String, String> ruleSetPaths = const {},
    String? debugLogPath,
    String? clashApiSecret,
    int clashApiPort = 9090,
    String? defaultInterface,
    TailnetOptions? tailnet,
  }) {
    _validateNodes(contract.nodes);
    _validateGroup(contract);
    if (contract.paths != null) _validatePaths(contract);
    if (tailnet != null) {
      if (platform != AuroraPlatform.android &&
          platform != AuroraPlatform.ios) {
        throw ArgumentError('Tailnet is only supported on Android/iOS');
      }
      if (debugLogPath != null) {
        throw ArgumentError('Tailnet cannot be combined with debug logging');
      }
    }
    if (clashApiSecret != null && !platform.usesClashApi) {
      throw ArgumentError(
        'clashApiSecret is only valid for the windows/linux platforms',
      );
    }
    // A dual-path contract promises that every public flow exits through the
    // signed household IP. Split-routing modes and the Global CN shortlist
    // would bypass both paths (and the fail-closed selector), so compile dual
    // contracts with the strict Global skeleton regardless of a stale saved
    // Smart preference.
    final compiledMode = contract.paths == null ? mode : AuroraMode.global;
    final experimental = <String, dynamic>{
      // sing-box 1.13 persists selector choices whenever cache_file is enabled.
      // Path selection is connection-local. Every new process deliberately
      // starts blocked and the session supervisor releases only a verified
      // household path; no stale selector choice may override that boundary.
      'cache_file': contract.paths != null
          ? {'enabled': false}
          : compiledMode == AuroraMode.smart
          ? {'enabled': true, 'store_fakeip': false}
          : {'enabled': true},
    };
    if (platform.usesClashApi) {
      // The desktop runs the official sing-box binary; the app reads live state,
      // traffic and node latency here and switches nodes through it. Both the port
      // and the secret are **chosen fresh for every connection**: 9090 is the default
      // of Clash / mihomo / v2rayN, so it is very likely taken on a machine with any of
      // them installed, and a failed `external_controller` bind is fatal to sing-box,
      // which surfaces literally as "the core failed to start".
      experimental['clash_api'] = {
        'external_controller': '127.0.0.1:$clashApiPort',
        'secret': ?clashApiSecret,
      };
    }
    final config = <String, dynamic>{
      'log': debugLogPath != null
          ? {'level': 'debug', 'timestamp': true, 'output': debugLogPath}
          : {'level': 'info', 'timestamp': true},
      'dns': _dns(
        compiledMode,
        contract.network,
        publicDirectAllowed: contract.paths == null,
      ),
      'inbounds': [_inbound(platform, contract.network)],
      'outbounds': _outbounds(contract),
      'route': _route(
        compiledMode,
        ruleSetPaths,
        contract.network,
        publicDirectAllowed: contract.paths == null,
        defaultInterface: defaultInterface,
      ),
      'experimental': experimental,
    };
    if (tailnet != null) _addTailnet(config, tailnet);
    return config;
  }

  /// Add only dedicated Tailnet destinations. Public selectors, lease gates,
  /// DNS and route defaults remain those of the original contract compiler.
  static void _addTailnet(Map<String, dynamic> config, TailnetOptions options) {
    const endpointTag = 'aurora-tailnet';
    const dnsTag = 'dns-tailnet';
    final dns = config['dns'] as Map<String, dynamic>;
    final outbounds = config['outbounds'] as List<Map<String, dynamic>>;
    final servers = dns['servers'] as List<Map<String, dynamic>>;
    for (final entry in [
      ...config['inbounds'] as List<Map<String, dynamic>>,
      ...outbounds,
      ...servers,
    ]) {
      if (entry['tag'] == endpointTag || entry['tag'] == dnsTag) {
        throw ArgumentError('Contract collides with a reserved Tailnet tag');
      }
    }
    final proxy = outbounds.where((entry) => entry['tag'] == 'proxy').toList();
    if (proxy.length != 1 || proxy.single['type'] != 'selector') {
      throw ArgumentError('Tailnet requires a unique proxy selector');
    }
    // Authentication URLs must not enter normal or debug logs. Authentication
    // UI consumes the session-bound native notification in a separate layer.
    config['log'] = {'level': 'warn', 'timestamp': true};
    config['endpoints'] = [
      {
        'type': 'tailscale',
        'tag': endpointTag,
        'state_directory': options.stateDirectory,
        'hostname': options.hostname,
        'system_interface': false,
        'ephemeral': false,
        'accept_routes': false,
        'advertise_routes': <String>[],
        'advertise_exit_node': false,
        'detour': 'proxy',
      },
    ];
    dns['servers'] = <Map<String, dynamic>>[
      ...servers,
      {
        'type': 'tailscale',
        'tag': dnsTag,
        'endpoint': endpointTag,
        'accept_default_resolvers': false,
      },
    ];
    dns['rules'] = <Map<String, dynamic>>[
      {
        'domain_suffix': ['ts.net'],
        'server': dnsTag,
        'strategy': 'prefer_ipv4',
      },
      ...?dns['rules'] as List<Map<String, dynamic>>?,
    ];
    final route = config['route'] as Map<String, dynamic>;
    route['rules'] = <Map<String, dynamic>>[
      {
        'inbound': [endpointTag],
        'action': 'reject',
      },
      {
        'inbound': ['tun-in'],
        'network': ['tcp', 'udp'],
        'port': [53],
        'action': 'hijack-dns',
      },
      {
        'inbound': ['tun-in'],
        'ip_cidr': ['100.64.0.0/10', 'fd7a:115c:a1e0::/48'],
        'outbound': endpointTag,
      },
      {
        'inbound': ['tun-in'],
        'domain_suffix': ['ts.net'],
        'outbound': endpointTag,
      },
      ...route['rules'] as List<Map<String, dynamic>>,
    ];
  }

  /// Names that only mean something on the local machine or network and can never
  /// be answered by public DNS.
  ///
  /// Observed in a real core log: `lb._dns-sd._udp.0.232.23.10.in-addr.arpa`
  /// (Bonjour wide-area discovery), the reverse lookup of the TUN's **own address**,
  /// and `*.local` all went into dns-proxy. Each one makes a three-hop proxy
  /// round trip to 1.1.1.1 where it cannot possibly have an answer, and when the
  /// link degrades these queries time out in the queue together with the real ones.
  /// Answering NXDOMAIN on the spot is the correct unicast-DNS answer for these
  /// names; mDNS uses multicast and never passes through here.
  ///
  /// Reverse zones list only private/special ranges (RFC 1918, CGNAT, link-local,
  /// loopback, ULA); PTR lookups for public addresses still resolve normally, since
  /// traceroute/sshd and the like really use them.
  static List<String> get localOnlyDomainSuffixes => [
    '.local',
    'localhost',
    'home.arpa',
    'internal',
    'intranet',
    'lan',
    'private',
    'corp',
    'home',
    '10.in-addr.arpa',
    '168.192.in-addr.arpa',
    '254.169.in-addr.arpa',
    '127.in-addr.arpa',
    for (var i = 16; i <= 31; i++) '$i.172.in-addr.arpa',
    // Tailscale CGNAT 100.64.0.0/10: a home node's tailnet address lives in this range.
    for (var i = 64; i <= 127; i++) '$i.100.in-addr.arpa',
    // fe80::/10 link-local, fc00::/7 ULA (the TUN's v6 range fdfe: is inside it), ::1.
    '8.e.f.ip6.arpa',
    '9.e.f.ip6.arpa',
    'a.e.f.ip6.arpa',
    'b.e.f.ip6.arpa',
    'c.f.ip6.arpa',
    'd.f.ip6.arpa',
    '1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa',
  ];

  // ---- DNS (§6) ----
  static Map<String, dynamic> _dns(
    AuroraMode mode,
    NetworkPolicy network, {
    required bool publicDirectAllowed,
  }) {
    final rules = <Map<String, dynamic>>[
      if (network.ipv6Mode == AuroraIpv6Mode.block)
        {
          'query_type': ['AAAA', if (network.suppressHttpsRecord) 'HTTPS'],
          'action': 'predefined',
        },
      {
        'domain_suffix': localOnlyDomainSuffixes,
        'domain_keyword': ['_dns-sd._udp'],
        'action': 'predefined',
        'rcode': 'NXDOMAIN',
      },
      if (mode == AuroraMode.smart)
        {'rule_set': 'geosite-cn', 'server': 'dns-direct'},
    ];
    final dns = <String, dynamic>{
      'servers': [
        {
          'tag': 'dns-proxy',
          'type': 'https',
          'server': '1.1.1.1',
          'detour': 'proxy',
          // One DoH connection, with every query multiplexed over it. Never add
          // `headers: {Connection: close}` (it was added once and removed): that opens a
          // separate TLS connection per cache miss, and each of those needs its own
          // link to the home node plus a handshake to the relay. Every time the tunnel
          // (re)starts, every program on the machine re-resolves at once, which turns into
          // dozens of three-hop handshakes. Measured on a cold start: 3 of 8 first-round
          // probes died on DNS without connection reuse, 0 with it; in the field 40 of 79
          // connections had their first probe round judged dead, so the watchdog switched
          // legs and restarted, which put it right back in a cold start. DoT does not work
          // either: its pool dials one connection per in-flight query, and all 8
          // first-round probes died on a cold start.
          //
          // Cost: when a group switches, sing-box always closes the internal connections
          // that went through it (DNS included). Only the one connection that was
          // **mid-dial** at the moment of the switch leaks onto the old node; it has just
          // connected and lives until the next switch. If that shared connection silently
          // stops answering, new queries wait at most until the first query's own DNS
          // deadline (10s) and then the transport is reset. A dial that hangs is worse:
          // x/net makes all queries wait for that one in-flight dial **without looking at
          // their own deadlines**, so if the dial never returns, DNS for the whole machine
          // stays dead. On TCP legs the dial is bound by a deadline (closing the
          // connection unblocks it); on HY2 legs it is not, because a QUIC stream write is
          // not woken by Close. That is why SS must never be wrapped in sing-mux again (see
          // the shadowsocks-2022 section below). Both 10s limits are longer than the
          // watchdog probe's 8s, so after the watchdog changes the selection it must wait the
          // full `selectionSettle` before judging. See docs/reliability-notes.md.
        },
        if (publicDirectAllowed)
          // new-style udp server dials directly by default — NO detour (would FATAL).
          {'tag': 'dns-direct', 'type': 'udp', 'server': '223.5.5.5'},
      ],
      'final': 'dns-proxy',
      // ipv4_only only affects sing-box's OWN resolutions; relayed client
      // queries still get AAAA answers, so block mode also adds an explicit
      // empty response. Encrypted browser/system DoH is application traffic
      // and cannot be rewritten by these DNS rules.
      'strategy': network.ipv6Mode == AuroraIpv6Mode.block
          ? 'ipv4_only'
          : 'prefer_ipv4',
      if (rules.isNotEmpty) 'rules': rules,
    };
    return dns;
  }

  static Map<String, dynamic> _inbound(
    AuroraPlatform platform,
    NetworkPolicy network,
  ) {
    if (platform == AuroraPlatform.desktop) {
      // No-admin CLI fallback: local SOCKS+HTTP proxy, no TUN driver / no admin.
      // Point the OS/browser proxy at 127.0.0.1:2080. (The native Windows app
      // uses AuroraPlatform.windows → TUN full-capture instead.)
      return {
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': 2080,
      };
    }
    return _tunInbound(platform, network);
  }

  // ---- TUN inbound (per platform, §5.2 step 2) ----
  static Map<String, dynamic> _tunInbound(
    AuroraPlatform platform,
    NetworkPolicy network,
  ) {
    // On desktop, "block IPv6" must mean **the TUN gets no IPv6 address**, not just
    // a reject rule in the routes.
    //
    // The leak: among the WFP rules sing-tun's `strict_route` installs on Windows,
    // the "block all outbound IPv6" one is conditional:
    // `if len(t.options.Inet6Address) == 0` (see Start() in sing-tun
    // tun_windows.go). We want IPv6 blocked yet used to give the TUN a v6 address
    // anyway, so that kernel-level backstop was **never installed**: only IPv6 that
    // entered the TUN is rejected by the route rules, while anything that did not
    // enter it (same-link on-link traffic, the gap while switching NICs, programs
    // that bind a physical NIC's address) went straight out.
    //
    // A second thing this fixes: with a v6 address configured, sing-tun also sets the
    // TUN's IPv6 DNS to `fdfe:dcba:9876::2`, but the first route rule is
    // "ip_version 6 -> reject", ahead of hijack-dns. Every query Windows sent to that
    // v6 DNS was bounced, and it had to wait to fall back to the v4 server; on a
    // machine that shows connected but behaves as if offline, that costs an extra
    // timeout on every resolution.
    //
    // Desktop only: mobile does not use sing-tun's Windows implementation (the
    // interface is built by VpnService / NEPacketTunnelProvider), so changing it
    // there would have no effect and would disturb two verified platform paths.
    final blockIpv6 =
        platform.isSvcDesktop && network.ipv6Mode == AuroraIpv6Mode.block;
    final address = switch (platform) {
      // gold-standard small subnet + auto_route; VpnService adds 0/0 + ::/0 routes
      // (M2-verified full capture).
      AuroraPlatform.android => [
        '$auroraTunHostV4Desktop/30',
        '$auroraTunHostV6/126',
      ],
      // NetworkExtension memory limits → small v4/v6 subnet.
      AuroraPlatform.ios => ['$auroraTunHostV4Mobile/24', '$auroraTunHostV6/64'],
      // Desktop full-capture (wintun / TUN driver): same subnet as Android;
      // sing-box's auto_route installs 0/0 + ::/0 routes. No NE memory cap.
      AuroraPlatform.windows || AuroraPlatform.linux => [
        '$auroraTunHostV4Desktop/30',
        if (!blockIpv6) '$auroraTunHostV6/126',
      ],
      AuroraPlatform.desktop => throw StateError(
        'desktop uses a mixed inbound, not tun',
      ),
    };
    return {
      'type': 'tun',
      'tag': 'tun-in',
      'address': address,
      'mtu': network.mtu,
      'auto_route': true,
      'strict_route': true,
      'stack': 'gvisor',
      // Only desktop gets a fixed name: on mobile the interface is created by
      // VpnService / NEPacketTunnelProvider, so a name here would have no effect and
      // might be rejected by the platform.
      if (platform.isSvcDesktop) 'interface_name': auroraTunInterfaceName,
    };
  }

  // ---- outbounds: selector + urltest + nodes + direct ----
  static List<Map<String, dynamic>> _outbounds(AuroraContract c) {
    if (c.paths != null) return _dualPathOutbounds(c);
    return _legacyOutbounds(c);
  }

  static List<Map<String, dynamic>> _dualPathOutbounds(AuroraContract c) {
    final paths = c.paths!;
    final pathOrder = [paths.preferred, ...c.pathPolicy!.fallbackOrder];
    return [
      {
        'type': 'selector',
        'tag': c.outboundGroup.selectorTag,
        'outbounds': [
          ...pathOrder.map((pathId) => paths.items[pathId]!.groupTag),
          auroraFailClosedOutboundTag,
        ],
        'default': auroraFailClosedOutboundTag,
        // A safety transition must also terminate flows that were established
        // through the previously selected path. sing-box otherwise keeps them
        // alive after the selector changes.
        'interrupt_exist_connections': true,
      },
      for (final pathId in pathOrder)
        {
          'type': 'urltest',
          'tag': paths.items[pathId]!.groupTag,
          'outbounds': paths.items[pathId]!.members,
          'url': c.outboundGroup.urltestUrl,
          'interval': capUrltestInterval(c.outboundGroup.urltestInterval),
          'tolerance': 50,
          // Regression guard: interrupt_exist_connections was once added here too.
          // urltest is a purely latency-ranked re-election, and whenever one member is
          // slightly faster within the tolerance (50ms) it re-elects; that is jitter, not
          // a failure. With the flag, every bit of latency noise would kick all existing
          // connections, which shows up as "the connection drops for a moment and
          // recovers". Only a selector change is decisive (the user pinning a path / a
          // safety transaction moving traffic), so do not add it back here.
        },
      for (final node in c.nodes) _nodeToOutbound(node),
      {'type': 'block', 'tag': auroraFailClosedOutboundTag},
      {'type': 'direct', 'tag': 'direct'},
    ];
  }

  static List<Map<String, dynamic>> _legacyOutbounds(AuroraContract c) {
    final g = c.outboundGroup;
    final selectableNodeIds = c.nodes
        .where((node) => node.role != 'entry')
        .map((node) => node.id)
        .toSet();
    final selectorMembers = g.selectorMembers
        .where((tag) => tag == g.urltestTag || selectableNodeIds.contains(tag))
        .toList();
    final urltestMembers = g.urltestMembers
        .where(selectableNodeIds.contains)
        .toList();

    // Keep a urltest inside each family: once "Direct" is pinned, fault tolerance
    // across the REALITY/Hy2/SS protocols continues automatically. With only one
    // family there is nothing to choose between, so no group is emitted.
    final families = c.routeFamilies;
    final familyGroups = <Map<String, dynamic>>[];
    final familyTags = <String>[];
    if (families.length > 1) {
      final nodeIds = c.nodes.map((n) => n.id).toSet();
      for (final family in families) {
        final tag = 'via-$family';
        if (nodeIds.contains(tag) ||
            tag == g.selectorTag ||
            tag == g.urltestTag) {
          throw ArgumentError(
            'route family group "$tag" collides with an existing outbound tag',
          );
        }
        final members = c.nodesByFamily[family]!
            .where(urltestMembers.contains)
            .toList();
        if (members.isEmpty) continue;
        familyTags.add(tag);
        familyGroups.add({
          'type': 'urltest',
          'tag': tag,
          'outbounds': members,
          'url': g.urltestUrl,
          'interval': capUrltestInterval(g.urltestInterval),
          'tolerance': 50,
          // Regression guard: this once said "re-election must terminate existing
          // connections on the old member" and set interrupt_exist_connections: true. But
          // via-* groups are purely latency-ranked urltest groups, and whenever a member
          // within the family is slightly faster (tolerance 50ms) a re-election fires;
          // nearly all of them are jitter, not a member actually going down. With the flag,
          // a via-relay group kept flapping its election between reality/ss/hy2 (hy2 kept
          // winning because it handshakes fastest while its throughput stays at 0KB/s),
          // which showed up as "the VPN drops for a moment and recovers". Only a selector
          // (see the selector under legacyOutbounds below) makes a decisive decision (the
          // user pinning a route family / GoodputGate demoting proactively) and should
          // terminate old connections; a urltest group should not.
        });
      }
    }

    final selectorOutbounds = <String>[];
    for (final tag in selectorMembers) {
      selectorOutbounds.add(tag);
      if (tag == g.urltestTag) selectorOutbounds.addAll(familyTags);
    }

    return [
      {
        'type': 'selector',
        'tag': g.selectorTag,
        'outbounds': selectorOutbounds,
        'default': g.selectorDefault,
        'interrupt_exist_connections': true,
      },
      {
        'type': 'urltest',
        'tag': g.urltestTag,
        'outbounds': urltestMembers,
        'url': g.urltestUrl,
        'interval': capUrltestInterval(g.urltestInterval),
        'tolerance': 50,
        // Regression guard: do not add interrupt_exist_connections back here. The
        // reason is the same as in the familyGroups comment above: urltest is a
        // latency-ranked re-election, nearly all re-elections are jitter rather than a
        // member going down, and with the flag every blip turns into a full disconnect.
        // Only the selector above should terminate old connections.
      },
      ...familyGroups,
      for (final node in c.nodes) _nodeToOutbound(node),
      {'type': 'direct', 'tag': 'direct'},
    ];
  }

  /// Fail-loud chain validation:
  /// 1. a node's [detour] must reference an existing node id;
  /// 2. a node whose server is a Tailscale CGNAT address (100.64.0.0/10)
  ///    MUST carry a detour — the client can't reach the tailnet directly,
  ///    only via an on-tailnet entry outbound.
  static void _validateNodes(List<AuroraNode> nodes) {
    final ids = nodes.map((n) => n.id).toSet();
    if (nodes.isEmpty) {
      throw ArgumentError('contract must contain at least one node');
    }
    if (ids.length != nodes.length) {
      throw ArgumentError('contract node ids must be unique');
    }
    for (final n in nodes) {
      final hasDetour = n.detour != null && n.detour!.isNotEmpty;
      if (hasDetour && !ids.contains(n.detour)) {
        throw ArgumentError(
          'node "${n.id}" detours to unknown node "${n.detour}"',
        );
      }
      if (_isCgnat(n.server) && !hasDetour) {
        throw ArgumentError(
          'node "${n.id}" server ${n.server} is a Tailscale CGNAT address '
          'and requires a detour',
        );
      }
    }
    _validateDetourGraph(nodes);
  }

  static void _validateDetourGraph(List<AuroraNode> nodes) {
    final byId = {for (final node in nodes) node.id: node};
    final visiting = <String>{};
    final visited = <String>{};

    void visit(String id) {
      if (visited.contains(id)) return;
      if (!visiting.add(id)) {
        throw ArgumentError('detour graph contains a loop at node "$id"');
      }
      final target = byId[id]!.detour;
      if (target != null && target.isNotEmpty) visit(target);
      visiting.remove(id);
      visited.add(id);
    }

    for (final node in nodes) {
      visit(node.id);
    }
  }

  static void _validateGroup(AuroraContract contract) {
    final group = contract.outboundGroup;
    final nodeById = {for (final node in contract.nodes) node.id: node};
    final knownSelectorTags = {group.urltestTag, ...nodeById.keys, 'direct'};
    for (final tag in group.selectorMembers) {
      if (!knownSelectorTags.contains(tag)) {
        throw ArgumentError('selector references unknown outbound "$tag"');
      }
    }
    for (final tag in group.urltestMembers) {
      if (!nodeById.containsKey(tag)) {
        throw ArgumentError('urltest references unknown node "$tag"');
      }
    }
    final selectable = group.selectorMembers.where((tag) {
      if (tag == 'direct') return false;
      if (tag == group.urltestTag) return true;
      return nodeById[tag]?.role != 'entry';
    }).toList();
    final tested = group.urltestMembers
        .where((tag) => nodeById[tag]?.role != 'entry')
        .toList();
    if (selectable.isEmpty || tested.isEmpty) {
      throw ArgumentError('proxy selector/urltest has no fail-closed node');
    }
    if (!selectable.contains(group.selectorDefault)) {
      throw ArgumentError(
        'selector default "${group.selectorDefault}" is not selectable',
      );
    }
  }

  static void _validatePaths(AuroraContract contract) {
    final paths = contract.paths!;
    final policy = contract.pathPolicy!;
    final nodeById = {for (final node in contract.nodes) node.id: node};
    final reservedTags = {
      contract.outboundGroup.selectorTag,
      contract.outboundGroup.urltestTag,
      'direct',
      ...nodeById.keys,
    };
    final ownerByMember = <String, String>{};

    for (final entry in paths.items.entries) {
      final pathId = entry.key;
      final path = entry.value;
      if (reservedTags.contains(path.groupTag)) {
        throw ArgumentError(
          'paths.items.$pathId.group_tag collides with outbound "${path.groupTag}"',
        );
      }
      for (final member in path.members) {
        final node = nodeById[member];
        if (node == null) {
          throw ArgumentError(
            'paths.items.$pathId.members references unknown node "$member"',
          );
        }
        if (node.role == 'entry') {
          throw ArgumentError(
            'paths.items.$pathId.members cannot expose entry "$member"',
          );
        }
        final previousOwner = ownerByMember[member];
        if (previousOwner != null) {
          throw ArgumentError(
            'node "$member" belongs to both paths "$previousOwner" and "$pathId"',
          );
        }
        ownerByMember[member] = pathId;
      }
    }

    if (policy.fallback != 'home' || !paths.items.containsKey('home')) {
      throw ArgumentError('final fallback path must be home');
    }
    final homePath = paths.items['home']!;
    Set<String> validateRelayPath(String pathId, {required bool publicTarget}) {
      final definition = paths.items[pathId];
      if (definition == null) {
        throw ArgumentError('required path "$pathId" is missing');
      }
      final detours = <String>{};
      String? sharedTarget;
      for (final member in definition.members) {
        final node = nodeById[member]!;
        final targetValid = publicTarget
            ? contract.egress!.hasSignedLease &&
                  node.server == contract.egress!.homeName &&
                  node.port == 2053
            : _isCgnat(node.server) && node.port == 8388;
        if (!targetValid || node.protocol != 'shadowsocks-2022') {
          throw ArgumentError(
            'path member "$member" has an invalid household target',
          );
        }
        sharedTarget ??= node.server;
        if (node.server != sharedTarget) {
          throw ArgumentError('path members must share one household target');
        }
        final detour = node.detour;
        final entry = detour == null ? null : nodeById[detour];
        if (entry == null || entry.role != 'entry' || !detours.add(detour!)) {
          throw ArgumentError(
            'path members must use distinct relay entry detours',
          );
        }
      }
      return detours;
    }

    if (paths.preferred == 'relay') {
      if (paths.items.length != 2 || policy.fallbackOrder.length != 1) {
        throw ArgumentError('legacy relay path supports only relay then home');
      }
      validateRelayPath('relay', publicTarget: false);
    } else if (paths.preferred == 'relay_public') {
      if (paths.items.length != 3 ||
          policy.fallbackOrder.length != 2 ||
          policy.fallbackOrder[0] != 'relay_tailnet') {
        throw ArgumentError(
          'three-path order must be relay_public, relay_tailnet, home',
        );
      }
      final publicDetours = validateRelayPath('relay_public', publicTarget: true);
      final tailnetDetours = validateRelayPath('relay_tailnet', publicTarget: false);
      if (publicDetours.length != tailnetDetours.length ||
          !publicDetours.containsAll(tailnetDetours)) {
        throw ArgumentError('relay public and Tailnet paths must share entries');
      }
    } else {
      throw ArgumentError('unsupported preferred household path');
    }

    for (final member in homePath.members) {
      final node = nodeById[member]!;
      if (node.detour != null || _isCgnat(node.server)) {
        throw ArgumentError(
          'fallback path member "$member" must be a direct-home outbound',
        );
      }
    }

    final legacy = contract.outboundGroup;
    final homeMembers = homePath.members.toSet();
    for (final member in legacy.urltestMembers) {
      if (!homeMembers.contains(member)) {
        throw ArgumentError(
          'legacy urltest may only expose fallback home nodes',
        );
      }
    }
    for (final member in legacy.selectorMembers) {
      if (member != legacy.urltestTag && !homeMembers.contains(member)) {
        throw ArgumentError(
          'legacy selector may only expose fallback home nodes',
        );
      }
    }
  }

  static bool _isCgnat(String server) {
    final parts = server.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;
    return a == 100 && b >= 64 && b <= 127;
  }

  static Map<String, dynamic> _nodeToOutbound(AuroraNode n) {
    final p = n.params;
    final Map<String, dynamic> out;
    switch (n.protocol) {
      case 'vless-reality':
        out = {
          'type': 'vless',
          'tag': n.id,
          'server': n.server,
          'server_port': n.port,
          'uuid': p['uuid'],
          'flow': p['flow'] ?? 'xtls-rprx-vision',
          'tls': {
            'enabled': true,
            'server_name': p['sni'],
            'utls': {
              'enabled': true,
              'fingerprint': p['fingerprint'] ?? 'chrome',
            },
            'reality': {
              'enabled': true,
              'public_key': p['public_key'],
              'short_id': p['short_id'],
            },
          },
        };
        break;
      case 'hysteria2':
        final tls = <String, dynamic>{
          'enabled': true,
          'server_name': p['sni'],
          'alpn': List<String>.from(p['alpn'] as List? ?? const ['h3']),
        };
        final pinValue = p['certificate_public_key_sha256'];
        final certificateValue = p['certificate'];
        if (pinValue != null && certificateValue != null) {
          throw ArgumentError(
            'hysteria2 node "${n.id}" cannot set both SPKI pin and certificate',
          );
        }
        if (pinValue != null) {
          final pins = pinValue is List
              ? List<String>.from(pinValue)
              : <String>[pinValue.toString()];
          if (pins.isEmpty ||
              pins.any((pin) {
                try {
                  return base64.decode(pin).length != 32;
                } catch (_) {
                  return true;
                }
              })) {
            throw ArgumentError(
              'hysteria2 node "${n.id}" has an invalid base64 SHA-256 SPKI pin',
            );
          }
          tls['certificate_public_key_sha256'] = pins;
        } else if (certificateValue != null) {
          final certificate = certificateValue is List
              ? List<String>.from(certificateValue)
              : const LineSplitter()
                    .convert(certificateValue.toString())
                    .where((line) => line.isNotEmpty)
                    .toList();
          if (certificate.isEmpty) {
            throw ArgumentError(
              'hysteria2 node "${n.id}" has an empty certificate',
            );
          }
          tls['certificate'] = certificate;
        } else if (p['insecure'] == true) {
          // Legacy migration only. New generated contracts always pin the
          // self-signed home/VPS certificate instead of disabling validation.
          tls['insecure'] = true;
        }
        out = {
          'type': 'hysteria2',
          'tag': n.id,
          'server': n.server,
          'server_port': n.port,
          ..._hy2PortHopping(n),
          'password': p['password'],
          'tls': tls,
        };
        break;
      case 'vless-ws-tls':
        // CDN-fronted entry: the client dials a CDN anycast address, so an
        // IP-level block of the origin cannot reach it. The CDN terminates
        // TLS, which rules out REALITY; and xtls-rprx-vision cannot ride a
        // WebSocket, so no `flow` is emitted either.
        final uuid = p['uuid'];
        if (uuid is! String || uuid.isEmpty) {
          throw ArgumentError('vless-ws-tls node "${n.id}" is missing uuid');
        }
        final sni = p['sni'];
        if (sni is! String || sni.isEmpty) {
          throw ArgumentError('vless-ws-tls node "${n.id}" is missing sni');
        }
        final wsHost = p['host'];
        final transport = <String, dynamic>{
          'type': 'ws',
          'path': p['path'] is String && (p['path'] as String).isNotEmpty
              ? p['path']
              : '/',
          // Only set when it differs from the SNI: sing-box already sends the
          // server name as Host, and a redundant header is one more thing that
          // can disagree with the CDN's routing.
          if (wsHost is String && wsHost.isNotEmpty && wsHost != sni)
            'headers': {'Host': wsHost},
        };
        out = {
          'type': 'vless',
          'tag': n.id,
          'server': n.server,
          'server_port': n.port,
          'uuid': uuid,
          'tls': {
            'enabled': true,
            'server_name': sni,
            'utls': {
              'enabled': true,
              'fingerprint': p['fingerprint'] ?? 'chrome',
            },
          },
          'transport': transport,
        };
        break;
      case 'shadowsocks-2022':
        out = {
          'type': 'shadowsocks',
          'tag': n.id,
          'server': n.server,
          'server_port': n.port,
          'method': p['method'],
          'password': p['password'],
          // The contract's `multiplex: true` is deliberately ignored (older clients still
          // read it). sing-mux holds a client-wide lock while dialing a new session, and
          // with default parameters it dials whenever there is no idle session, so every
          // new connection on this leg queues and dials one at a time, and one stuck dial
          // freezes the whole leg: in one observed case a single dial hung for 9 minutes,
          // every new connection and the DoH dial on that leg queued behind it, and after
          // the watchdog switched legs DNS for the whole machine was still dead; and when
          // stopping the tunnel, Close needs the same lock, so closeService times out and
          // the extension is judged poisoned. Without mux each connection dials on its own
          // with its own deadline.
          // UDP used to ride inside mux sessions over TCP; the relay only allows TCP to the
          // home node, so UDP-over-TCP is required to keep that property.
          'udp_over_tcp': true,
        };
        break;
      default:
        throw ArgumentError('unknown protocol: ${n.protocol}');
    }
    if (n.detour != null && n.detour!.isNotEmpty) {
      out['detour'] = n.detour;
    }
    return out;
  }

  // Port hopping: every hop_interval switch to a fresh local UDP socket and pick
  // the destination port at random from server_ports; the server (sing-quic turns
  // off quic-go's path validation) simply follows packets arriving from the new
  // address. Some carriers throttle UDP per flow: with two instances running side by
  // side on such a network, the one that did not hop downloaded only 2.5MB in 240s
  // with a longest stall of 30s, while the one hopping every 10s moved 97.5MB with
  // a longest stall of 1.2s. Listing only `443:443` still changes the 4-tuple, just
  // not the server port. A wrong port range is a dead leg, so this fails to
  // compile rather than letting it through.
  static Map<String, dynamic> _hy2PortHopping(AuroraNode n) {
    final ports = n.params['server_ports'];
    final interval = n.params['hop_interval'];
    if (ports == null) {
      if (interval != null) {
        throw ArgumentError(
          'hysteria2 node "${n.id}" sets hop_interval without server_ports',
        );
      }
      return const {};
    }
    final ranges = ports is List ? ports : null;
    if (ranges == null ||
        ranges.isEmpty ||
        ranges.any((r) {
          final m = RegExp(r'^(\d{1,5}):(\d{1,5})$').firstMatch('$r');
          if (r is! String || m == null) return true;
          final start = int.parse(m[1]!);
          final end = int.parse(m[2]!);
          return start < 1 || end > 65535 || start > end;
        })) {
      throw ArgumentError(
        'hysteria2 node "${n.id}" needs server_ports as a list of "start:end"',
      );
    }
    if (interval != null &&
        (interval is! String ||
            !RegExp(r'^[1-9]\d*(s|m)$').hasMatch(interval))) {
      throw ArgumentError(
        'hysteria2 node "${n.id}" has an invalid hop_interval: $interval',
      );
    }
    return {
      'server_ports': List<String>.from(ranges),
      'hop_interval': ?interval,
    };
  }

  // ---- route (§5.2 step 4 + §6) ----
  static Map<String, dynamic> _route(
    AuroraMode mode,
    Map<String, String> ruleSetPaths,
    NetworkPolicy network, {
    bool publicDirectAllowed = true,
    String? defaultInterface,
  }) {
    final rules = <Map<String, dynamic>>[
      if (network.ipv6Mode == AuroraIpv6Mode.block)
        // This MUST run before sniff. After a TUN connection has been accepted
        // for sniffing, sing-box can only close an IPv6 connection; Chromium
        // treats that as a terminal ERR_CONNECTION_CLOSED instead of trying the
        // IPv4 address it already learned. Pre-match reject returns TCP RST /
        // ICMP unreachable, which triggers immediate IPv4 fallback.
        //
        // no_drop is equally important: the default reject action changes to
        // silent drop after 50 hits in 30 seconds. A GitHub feed can exceed
        // that threshold with one page of parallel avatar requests.
        {
          'ip_version': 6,
          'action': 'reject',
          'method': 'default',
          'no_drop': true,
        },
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
      {'ip_is_private': true, 'outbound': 'direct'},
    ];
    // Egress NIC: pinned if one was chosen, otherwise follow the system default
    // route.
    //
    // The failure this answers: a user with a wired connection plugged in wanted
    // traffic to leave only through Wi-Fi, yet it seemed to leak onto the cable.
    // `auto_detect_interface` makes sing-box bind its own outbound sockets to the
    // **default interface Windows picks**, which is the Ethernet adapter whenever the
    // cable is plugged in, regardless of what the user wants, and the app had no place
    // to express that wish.
    //
    // The two fields are mutually exclusive (sing-box docs: `default_interface` has
    // no effect while `auto_detect_interface` is on), so when pinning we must **omit**
    // auto_detect_interface rather than write both. The name comes from aurora-svc's
    // `/diagnose`; that list comes from Go's `net.Interfaces()`, the same FriendlyName
    // set sing-box's own interface monitor reads, so the string the user picks is
    // always one the core recognises.
    final pinned = defaultInterface?.trim() ?? '';
    final route = <String, dynamic>{
      'rules': rules,
      'default_domain_resolver': {
        'server': publicDirectAllowed ? 'dns-direct' : 'dns-proxy',
      },
      'final': 'proxy',
      if (pinned.isEmpty)
        'auto_detect_interface': true
      else
        'default_interface': pinned,
    };

    if (!publicDirectAllowed) {
      // Private LAN/Tailnet destinations remain local; every public route uses
      // the household selector so its block member can enforce fail-closed.
    } else if (mode == AuroraMode.global) {
      // baked CN-direct shortlist (matches gold global).
      rules.add({
        'domain_suffix': [
          'alipay.com',
          'gov.cn',
          'qq.com',
          'weixin.qq.com',
          '12306.cn',
          'icbc.com.cn',
        ],
        'outbound': 'direct',
      });
    } else {
      // smart: geosite/geoip rule-set split.
      rules.add({'rule_set': 'geosite-cn', 'outbound': 'direct'});
      rules.add({'rule_set': 'geoip-cn', 'outbound': 'direct'});
      rules.add({'rule_set': 'geosite-geolocation-!cn', 'outbound': 'proxy'});
      route['rule_set'] = [
        _localRuleSet('geosite-cn', ruleSetPaths),
        _localRuleSet('geoip-cn', ruleSetPaths),
        _localRuleSet('geosite-geolocation-!cn', ruleSetPaths),
      ];
    }
    return route;
  }

  static Map<String, dynamic> _localRuleSet(
    String tag,
    Map<String, String> paths,
  ) {
    return {
      'type': 'local',
      'tag': tag,
      'format': 'binary',
      'path': paths[tag] ?? '$tag.srs',
    };
  }
}
