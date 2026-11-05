import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/server_bundle.dart';
import '../../data/contract_repository.dart';

/// The one command that creates a server. Shown in the app so a new user does not
/// have to go looking for it.
const auroraInstallCommand =
    'curl -fsSL https://raw.githubusercontent.com/SparkyWen/aurora-public/main/install.sh | sudo bash';

/// Adds a server from a link printed by `install.sh`.
///
/// Reached from the first-run screen, from settings, and from a deep link when the
/// phone's camera scans the QR code. A deep link only pre-fills this page and never
/// imports on its own: a server you add sees your traffic, so a stray `aurora://`
/// link on a web page must not be able to reconfigure the VPN without a tap.
class AddServerPage extends StatefulWidget {
  const AddServerPage({super.key, this.deepLinkRoute});

  /// The route name the Flutter engine delivered for an `aurora://` link.
  final String? deepLinkRoute;

  @override
  State<AddServerPage> createState() => _AddServerPageState();
}

class _AddServerPageState extends State<AddServerPage> {
  final _controller = TextEditingController();
  AuroraLink? _pending;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final route = widget.deepLinkRoute;
    if (route != null) {
      try {
        _pending = AuroraLink.parseRoute(route);
      } on AuroraLinkException catch (error) {
        _error = error.message;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && mounted) {
      setState(() => _controller.text = data!.text!.trim());
    }
  }

  Future<void> _copyCommand() async {
    await Clipboard.setData(const ClipboardData(text: auroraInstallCommand));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Command copied')));
    }
  }

  Future<void> _addPasted() => _import(_controller.text);

  Future<void> _addPending() async {
    final route = widget.deepLinkRoute;
    if (route == null) return;
    final path = route.split('#').first;
    await _import(
      '$auroraLinkPrefix${path.startsWith('/') ? path.substring(1) : path}',
    );
  }

  Future<void> _import(String text) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final added = await ContractRepository.importText(text);
      if (!mounted) return;
      final names = added.isEmpty ? 'contract' : added.join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added $names. Reconnect to use it.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pendingCard(AuroraLink link) {
    final description = switch (link) {
      ServerBundle() => link.description,
      DeliveryLink() => 'control plane at ${link.host}',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add this server?', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(description, key: const Key('pending-server')),
            const SizedBox(height: 8),
            const Text(
              'Only add links you created yourself. A server you add can see '
              'which sites you visit.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _addPending,
                  child: const Text('Add server'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => setState(() => _pending = null),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    return Scaffold(
      appBar: AppBar(title: const Text('Add a server')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (pending != null) ...[_pendingCard(pending), const SizedBox(height: 16)],
          const Text(
            '1. Set up your server',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'On your VPS or home machine (Linux or macOS), run this one command. '
            'It prints a link and a QR code when it finishes.',
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Expanded(
                    child: SelectableText(
                      auroraInstallCommand,
                      style: TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy command',
                    onPressed: _copyCommand,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '2. Add it here',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          const Text(
            'On a phone, scan the QR code with your camera. Or paste the '
            'aurora:// link below. Share links (vless://, hysteria2://, ss://) '
            'and a contract JSON also work.',
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('server-link-field'),
            controller: _controller,
            minLines: 2,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'aurora://v1/...',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('add-server-button'),
                onPressed: _busy ? null : _addPasted,
                child: const Text('Add server'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _paste,
                child: const Text('Paste'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const Key('add-server-error'),
              style: const TextStyle(color: Colors.red),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Links hold your server\'s keys. They are stored only in this device\'s '
            'encrypted storage.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
