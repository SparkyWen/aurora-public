/// Parsed model of `aurora-contract.json` (architecture spec §5.1) — the abstract
/// node table the VPS delivers and the app compiles into sing-box JSON.
library;

/// Selector member used when neither household path has a verified egress.
/// It keeps the OS TUN alive while sing-box rejects public traffic.
const auroraFailClosedOutboundTag = 'fail-closed';

/// Exits whose contract entry has no `via` are assigned to this family.
///
/// **It must not be inferred as `direct`**: a missing `detour` only proves "there
/// is no relay hop", not "the exit is the home node". An overseas endpoint exit
/// added to the contract by hand has no detour either; inferred as `direct`, it
/// would sit in the "Direct" group next to the real home nodes, and when the user
/// pins "Direct" sing-box picks the lowest latency inside the group, so a
/// well-placed overseas server would win and traffic would silently leave from the
/// wrong place while the UI plainly says "Direct". A family says how traffic
/// reaches an exit; when nothing says so, the honest answer is "unspecified".
///
/// A contract builder writes the family on every exit, but builders can be
/// bypassed (a contract pasted by hand), so the client prefers to label it
/// honestly as "unspecified": promise less and never guess.
const auroraUnspecifiedRouteFamily = 'unspecified';

enum AuroraIpv6Mode { block, native }

/// Transport policy shared by every platform compiler target.
///
/// Defaults are deliberately conservative for hotel/cellular paths and for the
/// current home exit, which has no IPv6 egress.
class NetworkPolicy {
  const NetworkPolicy({
    this.mtu = 1400,
    this.ipv6Mode = AuroraIpv6Mode.block,
    this.suppressHttpsRecord = false,
  });

  final int mtu;
  final AuroraIpv6Mode ipv6Mode;
  final bool suppressHttpsRecord;

  factory NetworkPolicy.fromJson(Map<String, dynamic>? j) {
    final mtu = (j?['mtu'] as num?)?.toInt() ?? 1400;
    if (mtu < 1280 || mtu > 9000) {
      throw ArgumentError.value(mtu, 'network.mtu', 'must be 1280..9000');
    }
    final ipv6Value = (j?['ipv6_mode'] as String?) ?? 'block';
    final ipv6Mode = switch (ipv6Value) {
      'block' => AuroraIpv6Mode.block,
      'native' => AuroraIpv6Mode.native,
      _ => throw ArgumentError.value(
        ipv6Value,
        'network.ipv6_mode',
        'must be block or native',
      ),
    };
    return NetworkPolicy(
      mtu: mtu,
      ipv6Mode: ipv6Mode,
      suppressHttpsRecord: (j?['suppress_https_rr'] as bool?) ?? false,
    );
  }
}

class AuroraNode {
  AuroraNode({
    required this.id,
    required this.role,
    required this.protocol,
    required this.server,
    required this.port,
    required this.params,
    this.name,
    this.detour,
    this.group,
    String? via,
  }) : via =
           via ??
           (detour == null || detour.isEmpty
               ? auroraUnspecifiedRouteFamily
               : 'relay');

  final String id;
  final String? name;
  final String role;
  final String protocol; // vless-reality | hysteria2 | shadowsocks-2022
  final String server;
  final int port;
  final Map<String, dynamic> params;

  /// Optional outbound-chain upstream: this node's outbound dials its server
  /// THROUGH the outbound whose tag == [detour]. Used for home-exit chaining
  /// (home-via-* detours through us-* entry outbounds).
  final String? detour;

  /// The imported server this node belongs to (see `contract_editor.dart`).
  final String? group;

  /// Route family: **how traffic reaches this exit**. `direct` dials the exit's
  /// public address straight, `relay`/`cdn` go through the matching entry chain to
  /// reach it, and imported servers form a family named after the server. The family
  /// only decides the path.
  ///
  /// When the contract does not say, it is derived from **structure** rather than
  /// guessed from an id prefix (prefix matching is the fragile shape: a
  /// `relay-entry-` prefix misses `cdn-edge`), and only what the structure can
  /// really prove is derived: a `detour` implies going through a relay (`relay`);
  /// without one the destination is unknown ([auroraUnspecifiedRouteFamily]),
  /// **not** `direct`.
  final String via;

  factory AuroraNode.fromJson(Map<String, dynamic> j) => AuroraNode(
    id: j['id'] as String,
    name: j['name'] as String?,
    role: (j['role'] as String?) ?? 'proxy',
    protocol: j['protocol'] as String,
    server: j['server'] as String,
    port: (j['port'] as num).toInt(),
    params: Map<String, dynamic>.from(j['params'] as Map? ?? const {}),
    detour: j['detour'] as String?,
    group: j['group'] as String?,
    via: j['via'] as String?,
  );
}

class OutboundGroup {
  OutboundGroup({
    required this.selectorTag,
    required this.selectorMembers,
    required this.selectorDefault,
    required this.urltestTag,
    required this.urltestMembers,
    required this.urltestUrl,
    required this.urltestInterval,
  });

  final String selectorTag;
  final List<String> selectorMembers;
  final String selectorDefault;
  final String urltestTag;
  final List<String> urltestMembers;
  final String urltestUrl;
  final String urltestInterval;

  factory OutboundGroup.fromJson(Map<String, dynamic> j) {
    final sel = Map<String, dynamic>.from(j['selector'] as Map);
    final ut = Map<String, dynamic>.from(j['urltest'] as Map);
    return OutboundGroup(
      selectorTag: sel['tag'] as String,
      selectorMembers: List<String>.from(sel['members'] as List),
      selectorDefault: (sel['default'] as String?) ?? 'auto',
      urltestTag: ut['tag'] as String,
      urltestMembers: List<String>.from(ut['members'] as List),
      urltestUrl:
          (ut['url'] as String?) ?? 'https://www.gstatic.com/generate_204',
      urltestInterval: (ut['interval'] as String?) ?? '3m',
    );
  }
}

/// A path-level urltest group. Members are complete home-exit outbounds, not
/// raw relay entry transports: choosing any member must still end at home.
class AuroraPathDefinition {
  AuroraPathDefinition({required this.groupTag, required List<String> members})
    : members = List.unmodifiable(members);

  final String groupTag;
  final List<String> members;

  factory AuroraPathDefinition.fromJson(String pathId, Map<String, dynamic> j) {
    final groupTag = j['group_tag'] as String?;
    if (groupTag == null || groupTag.trim().isEmpty) {
      throw ArgumentError('paths.items.$pathId.group_tag must not be empty');
    }
    final rawMembers = j['members'];
    if (rawMembers is! List) {
      throw ArgumentError('paths.items.$pathId.members must be a list');
    }
    final members = rawMembers.map((value) => value.toString()).toList();
    if (members.isEmpty || members.any((member) => member.trim().isEmpty)) {
      throw ArgumentError('paths.items.$pathId.members must not be empty');
    }
    if (members.toSet().length != members.length) {
      throw ArgumentError('paths.items.$pathId.members must be unique');
    }
    return AuroraPathDefinition(groupTag: groupTag, members: members);
  }
}

/// Additive version-1 path table. A missing block means legacy home-direct
/// behavior; a present block is validated strictly instead of partly enabled.
class AuroraPaths {
  AuroraPaths({
    required this.preferred,
    required Map<String, AuroraPathDefinition> items,
  }) : items = Map.unmodifiable(items);

  final String preferred;
  final Map<String, AuroraPathDefinition> items;

  factory AuroraPaths.fromJson(Map<String, dynamic> j) {
    final preferred = j['preferred'] as String?;
    final rawItems = j['items'];
    if (preferred == null || preferred.trim().isEmpty) {
      throw ArgumentError('paths.preferred must not be empty');
    }
    if (rawItems is! Map || rawItems.isEmpty) {
      throw ArgumentError('paths.items must not be empty');
    }
    final items = <String, AuroraPathDefinition>{};
    for (final entry in rawItems.entries) {
      final pathId = entry.key.toString();
      if (pathId.trim().isEmpty || entry.value is! Map) {
        throw ArgumentError('paths.items contains an invalid path');
      }
      items[pathId] = AuroraPathDefinition.fromJson(
        pathId,
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
    if (!items.containsKey(preferred)) {
      throw ArgumentError(
        'paths.preferred references unknown path "$preferred"',
      );
    }
    final groupTags = items.values.map((path) => path.groupTag).toList();
    if (groupTags.toSet().length != groupTags.length) {
      throw ArgumentError('paths group_tag values must be unique');
    }
    return AuroraPaths(preferred: preferred, items: items);
  }
}

class PathHealthPolicy {
  const PathHealthPolicy({
    required this.rollingWindow,
    required this.minimumSuccessRate,
    required this.hardFailureRounds,
    required this.performanceFailureRounds,
    required this.latencyRatio,
    required this.latencyDeltaMs,
    required this.recoveryRounds,
    required this.recoveryHold,
    required this.flapWindow,
    required this.flapThreshold,
    required this.flapCooldown,
  });

  final int rollingWindow;
  final double minimumSuccessRate;
  final int hardFailureRounds;
  final int performanceFailureRounds;
  final double latencyRatio;
  final int latencyDeltaMs;
  final int recoveryRounds;
  final Duration recoveryHold;
  final Duration flapWindow;
  final int flapThreshold;
  final Duration flapCooldown;

  factory PathHealthPolicy.fromJson(Map<String, dynamic> j) {
    final rollingWindow = _requiredInt(j, 'rolling_window');
    final minimumSuccessRate = _requiredDouble(j, 'min_success_rate');
    final hardFailureRounds = _requiredInt(j, 'hard_fail_rounds');
    final performanceFailureRounds = _requiredInt(j, 'performance_fail_rounds');
    final latencyRatio = _requiredDouble(j, 'latency_ratio');
    final latencyDeltaMs = _requiredInt(j, 'latency_delta_ms');
    final recoveryRounds = _requiredInt(j, 'recovery_success_rounds');
    final recoverySeconds = _requiredInt(j, 'recovery_stable_seconds');
    final flapWindowSeconds = _requiredInt(j, 'flap_window_seconds');
    final flapThreshold = _requiredInt(j, 'flap_limit');
    final flapCooldownSeconds = _requiredInt(j, 'flap_cooldown_seconds');

    _checkRange('rolling_window', rollingWindow, 3, 100);
    if (minimumSuccessRate <= 0 || minimumSuccessRate > 1) {
      throw ArgumentError(
        'path_policy.health.min_success_rate must be > 0 and <= 1',
      );
    }
    _checkRange('hard_fail_rounds', hardFailureRounds, 1, rollingWindow);
    _checkRange(
      'performance_fail_rounds',
      performanceFailureRounds,
      1,
      rollingWindow,
    );
    if (latencyRatio < 1 || latencyRatio > 10) {
      throw ArgumentError(
        'path_policy.health.latency_ratio must be between 1 and 10',
      );
    }
    _checkRange('latency_delta_ms', latencyDeltaMs, 0, 60000);
    _checkRange('recovery_success_rounds', recoveryRounds, 1, rollingWindow);
    _checkRange('recovery_stable_seconds', recoverySeconds, 1, 86400);
    _checkRange('flap_window_seconds', flapWindowSeconds, 1, 86400);
    _checkRange('flap_limit', flapThreshold, 1, 100);
    _checkRange('flap_cooldown_seconds', flapCooldownSeconds, 1, 86400);

    return PathHealthPolicy(
      rollingWindow: rollingWindow,
      minimumSuccessRate: minimumSuccessRate,
      hardFailureRounds: hardFailureRounds,
      performanceFailureRounds: performanceFailureRounds,
      latencyRatio: latencyRatio,
      latencyDeltaMs: latencyDeltaMs,
      recoveryRounds: recoveryRounds,
      recoveryHold: Duration(seconds: recoverySeconds),
      flapWindow: Duration(seconds: flapWindowSeconds),
      flapThreshold: flapThreshold,
      flapCooldown: Duration(seconds: flapCooldownSeconds),
    );
  }
}

class AuroraPathPolicy {
  const AuroraPathPolicy({
    required this.mode,
    required this.fallback,
    required this.fallbackOrder,
    required this.health,
  });

  final String mode;
  final String fallback;
  final List<String> fallbackOrder;
  final PathHealthPolicy health;

  factory AuroraPathPolicy.fromJson(Map<String, dynamic> j, AuroraPaths paths) {
    final mode = j['mode'] as String?;
    final fallback = j['fallback'] as String?;
    if (mode != 'prefer_relay') {
      throw ArgumentError('path_policy.mode must be prefer_relay');
    }
    if (fallback == null || !paths.items.containsKey(fallback)) {
      throw ArgumentError(
        'path_policy.fallback references unknown path "$fallback"',
      );
    }
    if (fallback == paths.preferred) {
      throw ArgumentError(
        'path_policy.fallback must differ from paths.preferred',
      );
    }
    final rawFallbackOrder = j['fallback_order'];
    final fallbackOrder = rawFallbackOrder == null
        ? <String>[fallback]
        : rawFallbackOrder is List
        ? rawFallbackOrder.map((value) => value.toString()).toList()
        : throw ArgumentError('path_policy.fallback_order must be a list');
    if (fallbackOrder.isEmpty ||
        fallbackOrder.any((pathId) => !paths.items.containsKey(pathId)) ||
        fallbackOrder.contains(paths.preferred) ||
        fallbackOrder.toSet().length != fallbackOrder.length ||
        fallbackOrder.last != fallback) {
      throw ArgumentError('path_policy.fallback_order is invalid');
    }
    final orderedPaths = {paths.preferred, ...fallbackOrder};
    if (orderedPaths.length != paths.items.length ||
        !orderedPaths.containsAll(paths.items.keys)) {
      throw ArgumentError('path_policy must order every declared path');
    }
    final rawHealth = j['health'];
    if (rawHealth is! Map) {
      throw ArgumentError('path_policy.health must be present');
    }
    return AuroraPathPolicy(
      mode: mode!,
      fallback: fallback,
      fallbackOrder: List.unmodifiable(fallbackOrder),
      health: PathHealthPolicy.fromJson(Map<String, dynamic>.from(rawHealth)),
    );
  }
}

class EgressPolicy {
  const EgressPolicy({
    required this.expectedIpv4,
    required this.expectedCountry,
    required this.expectedAsn,
    this.leaseUrl,
    this.leaseKeyId,
    this.leasePublicKey,
    this.homeName,
  });

  final String expectedIpv4;
  final String expectedCountry;
  final String expectedAsn;
  final Uri? leaseUrl;
  final String? leaseKeyId;
  final String? leasePublicKey;
  final String? homeName;

  bool get hasSignedLease =>
      leaseUrl != null &&
      leaseKeyId != null &&
      leasePublicKey != null &&
      homeName != null;

  factory EgressPolicy.fromJson(Map<String, dynamic> j) {
    final ipv4 = (j['bootstrap_ipv4'] ?? j['expected_ipv4']) as String?;
    final country = j['expected_country'] as String?;
    final asn = j['expected_asn'] as String?;
    if (ipv4 == null || !_isIpv4(ipv4)) {
      throw ArgumentError(
        'egress.bootstrap_ipv4/expected_ipv4 must be a valid IPv4 address',
      );
    }
    if (country == null || !RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
      throw ArgumentError('egress.expected_country must be ISO alpha-2');
    }
    if (asn == null || !RegExp(r'^AS[1-9][0-9]*$').hasMatch(asn)) {
      throw ArgumentError('egress.expected_asn must look like AS64496');
    }
    final leaseUrlValue = j['lease_url'] as String?;
    final leaseKeyId = j['lease_key_id'] as String?;
    final leasePublicKey = j['lease_public_key'] as String?;
    final homeName = j['home_name'] as String?;
    final signedValues = [leaseUrlValue, leaseKeyId, leasePublicKey, homeName];
    final signedCount = signedValues.where((value) => value != null).length;
    if (signedCount != 0 && signedCount != signedValues.length) {
      throw ArgumentError('egress signed lease metadata must be complete');
    }
    Uri? leaseUrl;
    if (leaseUrlValue != null) {
      leaseUrl = Uri.tryParse(leaseUrlValue);
      if (leaseUrl == null ||
          leaseUrl.scheme != 'https' ||
          leaseUrl.host.isEmpty ||
          leaseUrl.path != '/v2/egress-lease' ||
          leaseUrl.hasQuery ||
          leaseUrl.hasFragment) {
        throw ArgumentError(
          'egress.lease_url must be the HTTPS lease endpoint',
        );
      }
      if (!_validLeaseKeyId(leaseKeyId!) ||
          !_validLeasePublicKey(leasePublicKey!) ||
          !_validDNSName(homeName!)) {
        throw ArgumentError('egress signed lease identity is invalid');
      }
    }
    return EgressPolicy(
      expectedIpv4: ipv4,
      expectedCountry: country,
      expectedAsn: asn,
      leaseUrl: leaseUrl,
      leaseKeyId: leaseKeyId,
      leasePublicKey: leasePublicKey,
      homeName: homeName,
    );
  }

  EgressPolicy copyWith({
    String? expectedIpv4,
    String? expectedCountry,
    String? expectedAsn,
    Uri? leaseUrl,
    String? leaseKeyId,
    String? leasePublicKey,
    String? homeName,
  }) => EgressPolicy(
    expectedIpv4: expectedIpv4 ?? this.expectedIpv4,
    expectedCountry: expectedCountry ?? this.expectedCountry,
    expectedAsn: expectedAsn ?? this.expectedAsn,
    leaseUrl: leaseUrl ?? this.leaseUrl,
    leaseKeyId: leaseKeyId ?? this.leaseKeyId,
    leasePublicKey: leasePublicKey ?? this.leasePublicKey,
    homeName: homeName ?? this.homeName,
  );
}

bool _validLeaseKeyId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(value);

bool _validLeasePublicKey(String value) {
  try {
    return Uri.parse('data:;base64,$value').data?.contentAsBytes().length == 32;
  } catch (_) {
    return false;
  }
}

bool _validDNSName(String value) {
  if (value.isEmpty ||
      value.length > 253 ||
      value != value.toLowerCase() ||
      value.endsWith('.')) {
    return false;
  }
  final labels = value.split('.');
  if (labels.length < 2) return false;
  return labels.every(
    (label) =>
        label.isNotEmpty &&
        label.length <= 63 &&
        RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$').hasMatch(label),
  );
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value) {
    throw ArgumentError('path_policy.health.$key must be an integer');
  }
  return value.toInt();
}

double _requiredDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw ArgumentError('path_policy.health.$key must be numeric');
  }
  return value.toDouble();
}

void _checkRange(String key, int value, int minimum, int maximum) {
  if (value < minimum || value > maximum) {
    throw ArgumentError(
      'path_policy.health.$key must be between $minimum and $maximum',
    );
  }
}

bool _isIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    if (part.isEmpty || (part.length > 1 && part.startsWith('0'))) return false;
    final number = int.tryParse(part);
    return number != null && number >= 0 && number <= 255;
  });
}

/// The `delivery` block — where the app pulls a fresh contract from. The
/// control plane (Cloudflare Worker, [primary]) is reachable WITHOUT the tunnel
/// (CDN anycast), so a fresh install can bootstrap even in China. Non-HTTP
/// channels (e.g. `tailscale:`) are kept for reference but not fetched directly.
class DeliveryInfo {
  const DeliveryInfo({
    this.primary,
    this.fallbacks = const [],
    this.token,
    this.getDomain,
    this.signingKeyId,
    this.signingPublicKey,
  });

  final String? primary;
  final List<String> fallbacks;
  final String? token;
  final String? getDomain;

  /// The Ed25519 key remote contracts must be signed with. It arrives inside a
  /// contract the user explicitly imported, so trust is established once by that
  /// act and then carried forward (a signed update can rotate it). There is no
  /// key compiled into the app: anyone can self-host with their own.
  final String? signingKeyId;
  final String? signingPublicKey;

  /// Whether a fetched contract could be verified at all. Without a pinned key
  /// there is nothing to check a download against, so the app never fetches.
  bool get canVerifyRemote =>
      signingPublicKey != null && signingPublicKey!.isNotEmpty;

  /// Fetchable contract URLs in priority order: control-plane primary, then
  /// fallbacks. Only http(s) — drops `tailscale:`/other schemes the app can't
  /// fetch before the tunnel is up.
  List<String> get fetchUrls => [
    if (primary != null && primary!.isNotEmpty) primary!,
    ...fallbacks,
  ].where((u) => u.startsWith('http://') || u.startsWith('https://')).toList();

  factory DeliveryInfo.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const DeliveryInfo();
    final signing = j['signing'] is Map
        ? Map<String, dynamic>.from(j['signing'] as Map)
        : const <String, dynamic>{};
    return DeliveryInfo(
      signingKeyId: signing['key_id'] as String?,
      signingPublicKey: signing['public_key'] as String?,
      primary: j['primary'] as String?,
      fallbacks:
          (j['fallbacks'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      token: j['token'] as String?,
      getDomain: j['get_domain'] as String?,
    );
  }
}

class AuroraContract {
  AuroraContract({
    required this.version,
    required this.defaultMode,
    required this.nodes,
    required this.outboundGroup,
    this.revision = 0,
    this.delivery = const DeliveryInfo(),
    this.network = const NetworkPolicy(),
    this.paths,
    this.pathPolicy,
    this.egress,
    this.updated,
    this.defaultFamily,
  });

  final int version;
  final int revision;
  final String? updated;
  final String defaultMode; // smart | global

  /// Route family to use before the user has chosen one.
  final String? defaultFamily;
  final List<AuroraNode> nodes;
  final OutboundGroup outboundGroup;
  final DeliveryInfo delivery;
  final NetworkPolicy network;
  final AuroraPaths? paths;
  final AuroraPathPolicy? pathPolicy;
  final EgressPolicy? egress;

  static const _familyOrder = ['direct', 'relay', 'cdn'];

  /// The route families that actually exist in the contract, in a stable order (known families first, unknown ones after in alphabetical order).
  List<String> get routeFamilies {
    final present = nodesByFamily.keys.toList();
    present.sort((a, b) {
      final ai = _familyOrder.indexOf(a);
      final bi = _familyOrder.indexOf(b);
      if (ai != bi) return (ai == -1 ? 1 << 20 : ai).compareTo(bi == -1 ? 1 << 20 : bi);
      return a.compareTo(b);
    });
    return present;
  }

  /// Family -> selectable node ids. An entry can only be reached via detour; it is not an exit and does not take part.
  Map<String, List<String>> get nodesByFamily {
    final byFamily = <String, List<String>>{};
    for (final node in nodes) {
      if (node.role == 'entry') continue;
      byFamily.putIfAbsent(node.via, () => <String>[]).add(node.id);
    }
    return byFamily;
  }

  factory AuroraContract.fromJson(Map<String, dynamic> j) {
    final profile = Map<String, dynamic>.from(j['profile'] as Map? ?? const {});
    final rawPaths = j['paths'];
    final rawPathPolicy = j['path_policy'];
    final rawEgress = j['egress'];
    final additiveFields = [rawPaths, rawPathPolicy, rawEgress];
    final presentCount = additiveFields.where((value) => value != null).length;
    if (presentCount != 0 && presentCount != additiveFields.length) {
      throw ArgumentError(
        'paths, path_policy, and egress must be present together',
      );
    }
    final paths = rawPaths == null
        ? null
        : AuroraPaths.fromJson(Map<String, dynamic>.from(rawPaths as Map));
    final contract = AuroraContract(
      version: (j['version'] as num?)?.toInt() ?? 1,
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      updated: j['updated'] as String?,
      defaultMode: (profile['default_mode'] as String?) ?? 'smart',
      defaultFamily: profile['default_family'] as String?,
      nodes: (j['nodes'] as List)
          .map((e) => AuroraNode.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      outboundGroup: OutboundGroup.fromJson(
        Map<String, dynamic>.from(j['outbound_group'] as Map),
      ),
      delivery: DeliveryInfo.fromJson(
        j['delivery'] == null
            ? null
            : Map<String, dynamic>.from(j['delivery'] as Map),
      ),
      network: NetworkPolicy.fromJson(
        j['network'] == null
            ? null
            : Map<String, dynamic>.from(j['network'] as Map),
      ),
      paths: paths,
      pathPolicy: rawPathPolicy == null
          ? null
          : AuroraPathPolicy.fromJson(
              Map<String, dynamic>.from(rawPathPolicy as Map),
              paths!,
            ),
      egress: rawEgress == null
          ? null
          : EgressPolicy.fromJson(Map<String, dynamic>.from(rawEgress as Map)),
    );
    contract._validateTopology();
    return contract;
  }

  void _validateTopology() {
    final byId = <String, AuroraNode>{};
    for (final node in nodes) {
      if (node.id.trim().isEmpty || byId.containsKey(node.id)) {
        throw ArgumentError('nodes must have unique nonempty ids');
      }
      byId[node.id] = node;
    }
    for (final node in nodes) {
      final detour = node.detour;
      if (detour == null) continue;
      final target = byId[detour];
      if (target == null || target.role != 'entry') {
        throw ArgumentError('node detour must reference an entry node');
      }
    }
    final pathTable = paths;
    if (pathTable == null) return;
    final assigned = <String>{};
    for (final definition in pathTable.items.values) {
      for (final member in definition.members) {
        final node = byId[member];
        if (node == null || node.role == 'entry' || !assigned.add(member)) {
          throw ArgumentError(
            'path members must be unique existing household nodes',
          );
        }
      }
    }
    for (final member in outboundGroup.urltestMembers) {
      final node = byId[member];
      if (node == null || node.role == 'entry') {
        throw ArgumentError('legacy urltest may contain household nodes only');
      }
    }
    for (final member in outboundGroup.selectorMembers) {
      if (member == outboundGroup.urltestTag) continue;
      final node = byId[member];
      if (node == null || node.role == 'entry') {
        throw ArgumentError('legacy selector may contain household nodes only');
      }
    }
  }
}
