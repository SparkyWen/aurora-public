// The ports a multi-path contract must use for the home node's Shadowsocks target.
// ConfigCompiler checks the same two values in app/lib/core/config_compiler.dart when
// it compiles such a contract, so change them together: a contract accepted here and
// refused there would publish cleanly and then fail on every device.
const HOME_PUBLIC_PORT = 2053;
const HOME_TAILNET_PORT = 8388;

function fail(message) {
  throw new Error(`refusing to publish contract: ${message}`);
}

function isCgnat(value) {
  const parts = String(value).split('.').map(Number);
  return parts.length === 4 &&
    parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255) &&
    parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127;
}

export function normalizeContractCompatibility(contract) {
  const egress = contract?.egress;
  if (egress?.bootstrap_ipv4 && !egress.expected_ipv4) {
    egress.expected_ipv4 = egress.bootstrap_ipv4;
  }
  return contract;
}

export function validatePublishableContract(contract) {
  if (!contract || !Array.isArray(contract.nodes) || contract.nodes.length === 0) {
    fail('nodes must not be empty');
  }
  const nodes = new Map();
  for (const node of contract.nodes) {
    if (!node?.id || nodes.has(node.id)) fail('node ids must be present and unique');
    nodes.set(node.id, node);
  }

  validateDetours(nodes);

  const additive = [contract.paths, contract.path_policy, contract.egress];
  const present = additive.filter((value) => value != null).length;
  if (present === 0) return;
  if (present !== additive.length) fail('paths, path_policy, and egress must be present together');

  const items = contract.paths?.items;
  if (!items || typeof items !== 'object' || Array.isArray(items)) {
    fail('paths.items must be an object');
  }
  const preferred = contract.paths.preferred;
  const fallback = contract.path_policy?.fallback;
  if (!items[preferred] || !items[fallback] || preferred === fallback) {
    fail('preferred and fallback paths must exist and differ');
  }
  if (contract.path_policy.mode !== 'prefer_relay') fail('path_policy.mode must be prefer_relay');

  const selectorTag = contract.outbound_group?.selector?.tag;
  const legacyUrltestTag = contract.outbound_group?.urltest?.tag;
  const reserved = new Set(['direct', selectorTag, legacyUrltestTag, ...nodes.keys()]);
  const groups = new Set();
  const owner = new Map();
  for (const [pathId, path] of Object.entries(items)) {
    if (!path?.group_tag || reserved.has(path.group_tag) || groups.has(path.group_tag)) {
      fail(`unsafe or duplicate path group for ${pathId}`);
    }
    groups.add(path.group_tag);
    if (!Array.isArray(path.members) || path.members.length === 0) {
      fail(`empty path members for ${pathId}`);
    }
    for (const member of path.members) {
      if (member === 'direct') fail('direct cannot be a path member');
      const node = nodes.get(member);
      if (!node) fail(`unknown path member ${member}`);
      if (node.role === 'entry') fail(`entry ${member} cannot be a path member`);
      if (owner.has(member)) fail(`path member ${member} is assigned twice`);
      owner.set(member, pathId);
    }
  }

  const fallbackOrder = contract.path_policy.fallback_order ?? [fallback];
  if (!Array.isArray(fallbackOrder) || fallbackOrder.length === 0 ||
      fallbackOrder.includes(preferred) || fallbackOrder.at(-1) !== fallback ||
      new Set(fallbackOrder).size !== fallbackOrder.length ||
      fallbackOrder.some((pathId) => !items[pathId]) ||
      new Set([preferred, ...fallbackOrder]).size !== Object.keys(items).length) {
    fail('path_policy must order every declared path');
  }
  if (fallback !== 'home') fail('final fallback path must be home');

  const validateRelayPath = (pathId, publicTarget) => {
    const path = items[pathId];
    if (!path) fail(`required path ${pathId} is missing`);
    const detours = new Set();
    let sharedTarget;
    for (const member of path.members) {
      const node = nodes.get(member);
      const entry = nodes.get(node.detour);
      const validTarget = publicTarget
        ? node.server === contract.egress?.home_name && node.port === HOME_PUBLIC_PORT
        : isCgnat(node.server) && node.port === HOME_TAILNET_PORT;
      if (!validTarget || node.protocol !== 'shadowsocks-2022') {
        fail(`${publicTarget ? 'public ' : ''}household target for ${member} is invalid`);
      }
      sharedTarget ??= node.server;
      if (node.server !== sharedTarget || !entry || entry.role !== 'entry' ||
          detours.has(node.detour)) {
        fail(`${pathId} must use one household target and distinct relay entry detours`);
      }
      detours.add(node.detour);
    }
    return detours;
  };

  if (preferred === 'relay') {
    if (Object.keys(items).length !== 2 || fallbackOrder.length !== 1) {
      fail('legacy relay path supports only relay then home');
    }
    validateRelayPath('relay', false);
  } else if (preferred === 'relay_public') {
    if (Object.keys(items).length !== 3 || fallbackOrder.length !== 2 ||
        fallbackOrder[0] !== 'relay_tailnet') {
      fail('three-path order must be relay_public, relay_tailnet, home');
    }
    const signedLease = contract.egress?.lease_url &&
      contract.egress?.lease_key_id && contract.egress?.lease_public_key &&
      contract.egress?.home_name;
    if (!signedLease) fail('public household target requires signed lease identity');
    const publicDetours = validateRelayPath('relay_public', true);
    const tailnetDetours = validateRelayPath('relay_tailnet', false);
    if (publicDetours.size !== tailnetDetours.size ||
        [...publicDetours].some((detour) => !tailnetDetours.has(detour))) {
      fail('relay public and Tailnet paths must share entries');
    }
  } else {
    fail('unsupported preferred household path');
  }

  const homeMembers = new Set(items[fallback].members);
  for (const member of homeMembers) {
    const node = nodes.get(member);
    if (node.detour || isCgnat(node.server)) fail(`fallback member ${member} is not direct-home`);
  }
  for (const member of contract.outbound_group?.urltest?.members || []) {
    if (!homeMembers.has(member)) fail('legacy urltest may only contain home fallback members');
  }
  for (const member of contract.outbound_group?.selector?.members || []) {
    if (member !== legacyUrltestTag && !homeMembers.has(member)) {
      fail('legacy selector may only contain home fallback members');
    }
  }

  const expectedIp = contract.egress?.bootstrap_ipv4 ?? contract.egress?.expected_ipv4;
  if (contract.egress?.bootstrap_ipv4 && contract.egress?.expected_ipv4 &&
      contract.egress.bootstrap_ipv4 !== contract.egress.expected_ipv4) {
    fail('egress IPv4 compatibility fields must match');
  }
  if (!expectedIp || [...homeMembers].some((member) => nodes.get(member).server !== expectedIp)) {
    fail('egress bootstrap IPv4 must equal every direct-home server');
  }
}

function validateDetours(nodes) {
  const visiting = new Set();
  const visited = new Set();
  const visit = (id) => {
    if (visited.has(id)) return;
    if (visiting.has(id)) fail(`detour loop at ${id}`);
    visiting.add(id);
    const target = nodes.get(id).detour;
    if (target) {
      if (!nodes.has(target)) fail(`unknown detour ${target}`);
      visit(target);
    }
    visiting.delete(id);
    visited.add(id);
  };
  for (const id of nodes.keys()) visit(id);
}
