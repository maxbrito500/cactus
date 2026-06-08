import 'package:flutter/material.dart';

import 'model_catalog.dart';
import 'model_manager.dart';

/// Lets the user download additional models and pick which one is active.
/// Pops with the selected model id when the user switches (null if unchanged).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.models,
    required this.activeId,
    required this.manager,
  });

  final ModelManager manager;
  final String activeId;

  /// Catalog passed in so the host owns the source of truth.
  final List<ModelSpec> models;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Set<String> _installed = {};
  String? _downloadingId;
  double? _downloadProgress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refreshInstalled();
  }

  Future<void> _refreshInstalled() async {
    for (final m in widget.models) {
      if (await widget.manager.isInstalled(m)) _installed.add(m.id);
    }
    if (mounted) setState(() {});
  }

  Future<void> _download(ModelSpec spec) async {
    setState(() {
      _downloadingId = spec.id;
      _downloadProgress = 0;
      _error = null;
    });
    try {
      await widget.manager.ensureInstalled(spec, (phase, progress) {
        if (!mounted) return;
        setState(() => _downloadProgress = progress);
      });
      setState(() => _installed.add(spec.id));
    } catch (e) {
      setState(() => _error = 'Download failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _downloadingId = null;
          _downloadProgress = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ListView(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          for (final m in widget.models) _modelTile(m),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Larger models are stronger but download more data and run slower '
              'on-device. The default model is built into the app.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modelTile(ModelSpec m) {
    final isActive = m.id == widget.activeId;
    final isInstalled = _installed.contains(m.id);
    final isDownloading = _downloadingId == m.id;
    final busy = _downloadingId != null;

    Widget trailing;
    if (isActive) {
      trailing = const Chip(
        avatar: Icon(Icons.check, size: 18),
        label: Text('Active'),
      );
    } else if (isDownloading) {
      trailing = SizedBox(
        width: 120,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: _downloadProgress),
            const SizedBox(height: 4),
            Text(
              _downloadProgress == null
                  ? 'Unpacking…'
                  : '${(_downloadProgress! * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      );
    } else if (isInstalled) {
      trailing = FilledButton(
        onPressed: busy ? null : () => Navigator.of(context).pop(m.id),
        child: const Text('Use'),
      );
    } else {
      trailing = OutlinedButton.icon(
        onPressed: busy ? null : () => _download(m),
        icon: const Icon(Icons.download, size: 18),
        label: const Text('Download'),
      );
    }

    return ListTile(
      title: Text(m.name),
      subtitle: Text(m.sizeLabel),
      trailing: trailing,
    );
  }
}
