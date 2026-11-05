import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../../core/aurora_bridge.dart';
import '../../core/aurora_bridge_factory.dart';
import '../../core/aurora_bridge_svc.dart';
import '../../core/contract_editor.dart';
import '../../core/svc_installer.dart';
import '../../data/contract_repository.dart';
import '../../data/secure_store.dart';
import '../servers/add_server_page.dart';
import 'diagnostics_page.dart';

/// What to do with a saved exit adapter given this particular adapter list: which one to show, and whether to clear the saved value.
///
/// This is a pure function because there is a distinction here that is **very easy to get backwards**: an empty list does not mean "that adapter is gone",
/// only that this time nothing could be asked (the service is not running, a firewall blocked it, a timeout). Conflating the two means
/// that opening Settings once while the service is unreachable silently wipes the pinned choice.
///
/// Conversely, when the list was obtained and the saved adapter really is not in it (cable unplugged, different machine), it must fall back to
/// automatic: compiling a name the core cannot find into the config would make every later connection fail.
@visibleForTesting
({String? pinned, bool clearSaved}) resolveEgressPin(
  String? saved,
  List<String> listed,
) {
  final wanted = saved?.trim() ?? '';
  if (wanted.isEmpty) return (pinned: null, clearSaved: false);
  if (listed.isEmpty) return (pinned: wanted, clearSaved: false);
  if (listed.contains(wanted)) return (pinned: wanted, clearSaved: false);
  return (pinned: null, clearSaved: true);
}

/// Settings: manage servers and the desktop service. Imported contracts and keys
/// live only in flutter_secure_storage (encrypted), never in plain prefs or git.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AuroraBridge _bridge = createAuroraBridge();
  String _info = '';
  List<ContractServer> _servers = const [];
  bool _hasControlPlane = false;

  /// Windows/Linux: the tunnel is driven by aurora-svc running the official sing-box, and the exit adapter can be pinned.
  static bool get _usesSvc => Platform.isWindows || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    _refreshInfo();
    if (Platform.isWindows) _refreshSvcState();
    if (_usesSvc) _refreshEgressInterfaces();
  }

  // ---- Exit adapter (route.default_interface) ----

  List<String> _nics = const [];
  String? _pinnedNic;
  bool _nicLoading = true;

  Future<void> _refreshEgressInterfaces() async {
    final saved = (await SecureStore.loadEgressInterface())?.trim();
    final bridge = _bridge;
    final names = bridge is AuroraBridgeSvc
        ? await bridge.egressInterfaceCandidates()
        : const <String>[];
    if (!mounted) return;
    final decision = resolveEgressPin(saved, names);
    setState(() {
      _nics = names;
      _pinnedNic = decision.pinned;
      _nicLoading = false;
    });
    if (decision.clearSaved) await SecureStore.clearEgressInterface();
  }

  Future<void> _pinEgressInterface(String? name) async {
    setState(() => _pinnedNic = name);
    if (name == null) {
      await SecureStore.clearEgressInterface();
      _snack('Exit adapter set back to "follow system"; takes effect after reconnecting');
    } else {
      await SecureStore.saveEgressInterface(name);
      _snack('Exit adapter pinned to $name; takes effect after reconnecting');
    }
  }

  /// Windows only: whether the privileged helper is answering. The installer
  /// registers it, so this is normally "running" and the buttons are just repair.
  bool? _svcReady;
  bool _svcBusy = false;

  Future<void> _refreshSvcState() async {
    final ready = await SvcInstaller.isReady();
    if (mounted) setState(() => _svcReady = ready);
  }

  Future<void> _svcAction(Future<bool> Function() action, String verb) async {
    setState(() => _svcBusy = true);
    try {
      final ok = await action();
      await _refreshSvcState();
      _snack(ok ? 'Service ${verb.toLowerCase()}ed' : '$verb failed or was cancelled');
    } finally {
      if (mounted) setState(() => _svcBusy = false);
    }
  }

  Future<void> _refreshInfo() async {
    try {
      final contract = await ContractRepository.load();
      final servers = await ContractRepository.listServers();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _hasControlPlane = contract.delivery.canVerifyRemote;
        _info =
            'v${contract.version} · ${contract.nodes.length} nodes: '
            '${contract.nodes.map((n) => n.id).join(', ')}';
      });
    } on NoContractException {
      if (!mounted) return;
      setState(() {
        _servers = const [];
        _hasControlPlane = false;
        _info = 'No servers yet.';
      });
    } catch (e) {
      if (mounted) setState(() => _info = 'Could not read the contract: $e');
    }
  }

  Future<void> _confirmRemove(String group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $group?'),
        content: const Text(
          'You can add it again later with its link. Reconnect for this to take '
          'effect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => ContractRepository.removeServer(group), '$group removed');
    }
  }

  Future<void> _run(Future<void> Function() action, String okMsg) async {
    try {
      await action();
      await _refreshInfo();
      _snack(okMsg);
    } catch (e) {
      _snack('Failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Current contract',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(_info),
                ],
              ),
            ),
          ),
          if (Platform.isWindows) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Aurora service (Windows)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      switch (_svcReady) {
                        true => 'Status: running · no UAC prompt to connect/disconnect',
                        false =>
                          'Status: not running. Tap "Repair service" to reinstall it (one administrator prompt).',
                        null => 'Status: checking…',
                      },
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'The installer already installs this service; this is only for when it stops working (for example after upgrading from an old unzipped version).',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton.icon(
                          icon: const Icon(Icons.shield),
                          label: Text(_svcReady == true ? 'Repair service' : 'Install service'),
                          onPressed: _svcBusy
                              ? null
                              : () => _svcAction(SvcInstaller.install, 'Install'),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Uninstall service'),
                          onPressed: _svcBusy
                              ? null
                              : () => _svcAction(SvcInstaller.uninstall, 'Uninstall'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_usesSvc) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Exit adapter',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Which network adapter the tunnel\'s own traffic leaves through. By default it follows the system default route — '
                      'with a cable plugged in that is Ethernet, whether or not you would rather use Wi-Fi. '
                      'Pin one and only that one is used from then on.',
                      style: TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    if (_nicLoading)
                      const Text(
                        'Asking the service for local network adapters…',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      )
                    else if (_nics.isEmpty)
                      Text(
                        _pinnedNic == null
                            ? 'The service is not responding, so adapters cannot be listed for now. Come back after fixing the service.'
                            : 'The service is not responding, so adapters cannot be listed for now; "$_pinnedNic" is currently pinned, '
                                  'and it will not be cleared just because this lookup failed.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      )
                    else
                      DropdownButton<String?>(
                        isExpanded: true,
                        value: _pinnedNic,
                        onChanged: _pinEgressInterface,
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Follow system (automatic)'),
                          ),
                          for (final name in _nics)
                            DropdownMenuItem<String?>(
                              value: name,
                              child: Text(name),
                            ),
                        ],
                      ),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Re-read adapters'),
                      onPressed: _refreshEgressInterfaces,
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('Connection diagnostics'),
              subtitle: const Text('Path checks, home exit, DNS, IPv6, MTU and GitHub resources'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const DiagnosticsPage()),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Leak protection / kill switch',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'In the system VPN settings, turn on "Always-on VPN" and "Block connections without VPN" for Aurora, '
                    'so nothing leaks when the network drops or the device restarts.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.shield_outlined),
                    label: const Text('Open system VPN settings'),
                    onPressed: () => _bridge.openVpnSettings(),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Servers',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          for (final server in _servers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(server.group),
              subtitle: Text(server.host),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove ${server.group}',
                onPressed: () => _confirmRemove(server.group),
              ),
            ),
          if (_servers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No servers yet.'),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add a server'),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<bool>(
                      builder: (_) => const AddServerPage(),
                    ),
                  );
                  await _refreshInfo();
                },
              ),
              if (_hasControlPlane)
                OutlinedButton(
                  onPressed: () => _run(
                    () => ContractRepository.refresh().then((_) {}),
                    'Contract refreshed',
                  ),
                  child: const Text('Refresh contract'),
                ),
              if (_servers.isNotEmpty)
                OutlinedButton(
                  onPressed: () => _run(
                    ContractRepository.reset,
                    'All servers removed',
                  ),
                  child: const Text('Remove all servers'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Keys are stored only in this device\'s encrypted storage.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
