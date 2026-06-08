import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_prefs.dart';
import 'inference_isolate.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'settings_screen.dart';

void main() {
  runApp(const GeogramApp());
}

class GeogramApp extends StatelessWidget {
  const GeogramApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geogram chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D32)),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

enum AppPhase { preparing, downloading, loadingModel, ready, error }

class ChatMessage {
  ChatMessage(this.role, this.text);
  final String role; // 'user' or 'assistant'
  String text;
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ModelManager _models = ModelManager();
  final InferenceEngine _engine = InferenceEngine();
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  final List<ChatMessage> _messages = [];
  String _systemPrompt = kDefaultSystemPrompt;
  List<ModelSpec> _catalog = kBuiltinCatalog;
  String _activeModelId = kDefaultModelId;
  AppPhase _phase = AppPhase.preparing;
  String _statusText = 'Starting…';
  double? _progress;
  String? _lastStats;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _engine.start();
    _systemPrompt = await loadSystemPrompt();
    _catalog = await loadCatalog();
    final prefs = await SharedPreferences.getInstance();
    _activeModelId = prefs.getString('selected_model') ?? kDefaultModelId;
    // A previously-selected non-bundled model may be gone; if so, fall back to
    // the bundled default (which is always available).
    final spec = modelById(_catalog, _activeModelId);
    if (!spec.isBundled && !await _models.isInstalled(spec)) {
      _activeModelId = kDefaultModelId;
    }
    await _prepareAndLoad();
  }

  Future<void> _prepareAndLoad() async {
    final spec = modelById(_catalog, _activeModelId);
    setState(() {
      _phase = AppPhase.downloading;
      _statusText = 'Preparing model…';
      _progress = null;
    });
    try {
      final path = await _models.ensureInstalled(spec, (phase, progress) {
        if (!mounted) return;
        setState(() {
          _statusText = phase;
          _progress = progress;
        });
      });
      await _loadModel(path);
    } catch (e) {
      setState(() {
        _phase = AppPhase.error;
        _statusText = 'Failed to prepare model: $e';
      });
    }
  }

  Future<void> _openSettings() async {
    final newId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          activeId: _activeModelId,
          manager: _models,
        ),
      ),
    );
    // Persona and sideloaded models may have changed — reload them.
    _systemPrompt = await loadSystemPrompt();
    _catalog = await loadCatalog();
    if (newId == null || newId == _activeModelId) {
      if (mounted) setState(() {});
      return;
    }
    _activeModelId = newId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_model', newId);
    setState(() {
      _messages.clear();
      _lastStats = null;
    });
    await _prepareAndLoad();
  }

  Future<void> _loadModel(String modelDir) async {
    setState(() {
      _phase = AppPhase.loadingModel;
      _statusText = 'Loading model…';
      _progress = null;
    });
    try {
      await _engine.initModel(modelDir);
      setState(() => _phase = AppPhase.ready);
    } catch (e) {
      setState(() {
        _phase = AppPhase.error;
        _statusText = 'Failed to load model: $e';
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _generating) return;
    _input.clear();

    final assistant = ChatMessage('assistant', '');
    setState(() {
      _messages.add(ChatMessage('user', text));
      _messages.add(assistant);
      _generating = true;
      _lastStats = null;
    });
    _scrollToBottom();

    // Build the conversation: a system prompt followed by the full history
    // (excluding the still-empty assistant placeholder).
    final messagesJson = jsonEncode([
      {'role': 'system', 'content': _systemPrompt},
      ..._messages
          .where((m) => m != assistant)
          .map((m) => {'role': m.role, 'content': m.text}),
    ]);
    const options = '{"max_tokens":256,"temperature":0.7}';

    final run = _engine.complete(messagesJson, optionsJson: options);
    run.tokens.listen(
      (token) {
        setState(() => assistant.text += token);
        _scrollToBottom();
      },
      onError: (e) {
        setState(() {
          assistant.text += '\n[error: $e]';
          _generating = false;
        });
      },
    );
    try {
      final stats = await run.stats;
      // Fall back to the authoritative full response if streaming was empty.
      final full = (stats['response'] as String?)?.trim();
      if (assistant.text.isEmpty && full != null && full.isNotEmpty) {
        setState(() => assistant.text = full);
      }
      final tps = stats['decode_tps'];
      setState(() {
        _generating = false;
        if (tps is num) _lastStats = '${tps.toStringAsFixed(1)} tok/s';
      });
    } catch (_) {
      setState(() => _generating = false);
    }
    _scrollToBottom();
  }

  Future<void> _newChat() async {
    if (_generating) return;
    await _engine.reset();
    setState(() {
      _messages.clear();
      _lastStats = null;
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geogram chat'),
        actions: [
          if (_lastStats != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text(_lastStats!, style: const TextStyle(fontSize: 12)),
              ),
            ),
          if (_phase == AppPhase.ready)
            IconButton(
              tooltip: 'New chat',
              onPressed: (_generating || _messages.isEmpty) ? null : _newChat,
              icon: const Icon(Icons.add_comment_outlined),
            ),
          if (_phase == AppPhase.ready)
            IconButton(
              tooltip: 'Models',
              onPressed: _generating ? null : _openSettings,
              icon: const Icon(Icons.tune),
            ),
        ],
      ),
      body: switch (_phase) {
        AppPhase.ready => _buildChat(),
        AppPhase.error => _buildError(),
        _ => _buildLoading(),
      },
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(value: _progress),
          const SizedBox(height: 16),
          Text(_statusText),
          if (_progress != null) ...[
            const SizedBox(height: 8),
            Text('${(_progress! * 100).toStringAsFixed(0)}%'),
          ],
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(_statusText, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(onPressed: _bootstrap, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildChat() {
    return Column(
      children: [
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Text('Say hello to start chatting.'))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, i) => _bubble(_messages[i]),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _generating ? null : _send,
                icon: _generating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _bubble(ChatMessage m) {
    final isUser = m.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        // User text is shown verbatim; assistant replies are rendered as
        // markdown (bold, italics, lists, code, …).
        child: m.text.isEmpty
            ? const Text('…')
            : isUser
                ? Text(m.text)
                : MarkdownBody(
                    data: m.text,
                    shrinkWrap: true,
                    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                        .copyWith(p: Theme.of(context).textTheme.bodyMedium),
                  ),
      ),
    );
  }
}
