import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/aurora_bridge.dart';
import '../../core/aurora_bridge_factory.dart';
import '../../core/route_family.dart';

const _householdPathTags = {
  'relay-public-auto',
  'relay-tailnet-auto',
  'home-auto',
  // Backward-compatible two-path group while an old contract is active.
  'relay-auto',
};

/// The single-path contracts (the deployed home-direct one included) expose no
/// household-path group — only the plain `auto` urltest that every contract
/// compiles. Fall back to it so the page and its speed-test still work.
const _fallbackUrltestTag = 'auto';

/// The entry node is not listed here because it is not a member of any group: the compiler only emits entry nodes
/// as the target of a `detour`, and the members of selector/urltest are always chained exits.
/// This used to also filter group members by the `relay-entry-` prefix — that was a no-op (and missed `cdn-edge`),
/// and "guessing semantics from an id prefix" is exactly the pattern that caused an earlier incident; it is not kept in the template.
List<OutboundGroupInfo> visibleHouseholdPathGroups(
  Iterable<OutboundGroupInfo> groups,
) {
  final groupList = groups.toList();
  final household = groupList
      .where((group) => _householdPathTags.contains(group.tag))
      .toList();
  // When a family is manually locked the compiler emits only one `via-<family>` urltest group, which is not in
  // `_householdPathTags` — whether or not this contract has a real multi-path household grouping,
  // the locked group must still be shown, otherwise a user who tapped "only this route" sees no matching group on the Nodes page.
  final familyGroups = groupList
      .where((group) => group.tag.startsWith('via-'))
      .toList();
  if (household.isNotEmpty) return [...household, ...familyGroups];
  final fallback = groupList
      .where((group) => group.tag == _fallbackUrltestTag)
      .toList();
  return [...fallback, ...familyGroups];
}

String householdPathLabel(String tag) => switch (tag) {
  'relay-public-auto' => 'Relay to home (public)',
  'relay-tailnet-auto' => 'Relay to home (Tailnet)',
  'home-auto' => 'Home (direct)',
  'relay-auto' => 'Relay to home',
  'auto' => 'Auto speed test (home direct)',
  // The label of a locked family's group reuses the same names as the connect_page segmented control, to keep wording consistent.
  String s when s.startsWith('via-') => routeFamilyLabel(s.substring(4)),
  _ => tag,
};

/// Path-scoped protocol health. Only exit groups are listed; entry transports
/// are not exits and never appear as a member of one, so every visible member
/// still terminates at the household egress.
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final AuroraBridge _bridge = createAuroraBridge();
  List<OutboundGroupInfo> _groups = const [];
  StreamSubscription<List<OutboundGroupInfo>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _bridge.groupsStream().listen((g) {
      if (mounted) setState(() => _groups = g);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _delayLabel(OutboundItem i) => i.delayMs > 0 ? '${i.delayMs} ms' : '—';

  Color _delayColor(int ms) {
    if (ms <= 0) return Colors.grey;
    if (ms < 300) return Colors.green;
    if (ms < 800) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final visible = visibleHouseholdPathGroups(_groups);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nodes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.speed),
            tooltip: 'Speed test',
            onPressed: () {
              for (final g in visible) {
                _bridge.urlTest(g.tag);
              }
            },
          ),
        ],
      ),
      body: visible.isEmpty
          ? const Center(child: Text('Nodes appear once connected'))
          : ListView(
              children: [
                for (final g in visible) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      householdPathLabel(g.tag),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  for (final item in g.items)
                    ListTile(
                      leading: Icon(
                        item.tag == g.selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: item.tag == g.selected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      title: Text(item.tag),
                      subtitle: Text(item.type),
                      trailing: Text(
                        _delayLabel(item),
                        style: TextStyle(color: _delayColor(item.delayMs)),
                      ),
                      onTap: null,
                    ),
                ],
              ],
            ),
    );
  }
}
