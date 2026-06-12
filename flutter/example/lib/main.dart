import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:file_picker/file_picker.dart';

import 'package:flutter_tts/flutter_tts.dart';

import 'app_prefs.dart';
import 'assistant_channel.dart';
import 'background_indexer.dart';
import 'document_service.dart';
import 'inference_isolate.dart';
import 'model_catalog.dart';
import 'model_manager.dart';
import 'rag_index.dart';
import 'settings_screen.dart';
import 'system_voice.dart';
import 'voice_service.dart';

const Color _seedColor = Color(0xFF2E7D32);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initThemeMode();
  runApp(const EvaApp());
}

class EvaApp extends StatelessWidget {
  const EvaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: 'Eva',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: _seedColor,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: mode,
        home: const ChatScreen(),
      ),
    );
  }
}

enum AppPhase { preparing, downloading, loadingModel, ready, error }

class ChatMessage {
  ChatMessage(this.role, this.text, {this.imagePath, this.sources});
  final String role; // 'user' or 'assistant'
  String text;
  // Absolute path of an image the user attached to this message (vision chat).
  final String? imagePath;
  // Document sources cited for this answer (RAG), shown under the bubble.
  List<String>? sources;
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
  final ImagePicker _picker = ImagePicker();
  final VoiceService _voice = VoiceService();
  final SystemVoiceService _systemVoice = SystemVoiceService();
  final DocumentService _docs = DocumentService();
  bool _listening = false;
  VoiceEngine _voiceEngine = VoiceEngine.fast;
  String _voiceLocale = '';
  List<DocumentInfo> _documents = const [];
  String _corpusLocation = '';
  RagIndex? _rag;
  IndexingController? _indexer;
  bool _embedderReady = false;
  bool _docBusy = false;
  String _systemPrompt = kDefaultSystemPrompt;
  List<ModelSpec> _catalog = kBuiltinCatalog;
  String _activeModelId = kDefaultModelId;
  AppPhase _phase = AppPhase.preparing;
  String _statusText = 'Starting…';
  double? _progress;
  String? _lastStats;
  bool _generating = false;
  // Image queued by the user for the next message (vision models only).
  String? _pendingImagePath;
  // Digital-assistant mode (invoked via the power button): speaks replies and
  // auto-listens. _assistPending = a turn is queued until the model is ready.
  final FlutterTts _tts = FlutterTts();
  bool _assistMode = false;
  bool _assistPending = false;

  /// Whether the active model can see images (exposes the attach button).
  bool get _visionActive => modelById(_catalog, _activeModelId).isVision;

  @override
  void initState() {
    super.initState();
    _setupAssistant();
    _bootstrap();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _voice.dispose();
    _systemVoice.dispose();
    _tts.stop();
    _indexer?.removeListener(_onIndexerProgress);
    _indexer?.dispose();
    _rag?.close();
    super.dispose();
  }

  // ── Digital assistant (power-button invocation) ────────────────────────────

  /// Wires up assistant mode: handles invocations that arrive while running and
  /// detects whether this launch itself was an assistant invocation.
  Future<void> _setupAssistant() async {
    AssistantChannel.setAssistHandler(() {
      _assistMode = true;
      _assistPending = true;
      _tryStartAssistTurn();
    });
    if (await AssistantChannel.consumeAssistLaunch()) {
      _assistMode = true;
      _assistPending = true;
      _tryStartAssistTurn(); // no-op until the model is ready
    }
  }

  /// Starts a hands-free assist turn once the model is ready and idle.
  Future<void> _tryStartAssistTurn() async {
    if (!_assistPending || _phase != AppPhase.ready) return;
    if (_generating || _listening) return;
    _assistPending = false;
    await _startAssistListening();
  }

  /// Listens via the phone recognizer (auto-stops on silence), then sends the
  /// transcript. The reply is spoken because [_assistMode] is set.
  Future<void> _startAssistListening() async {
    await _tts.stop();
    await _voice.stop();
    await _systemVoice.stop();
    _input.clear();
    void onText(String t) {
      _input.text = t;
      _input.selection = TextSelection.collapsed(offset: t.length);
    }

    try {
      await _systemVoice.start(_voiceLocale, onText, onStopped: () {
        if (!mounted) return;
        setState(() => _listening = false);
        if (_input.text.trim().isNotEmpty && !_generating) _send();
      });
      if (mounted) setState(() => _listening = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Assistant voice unavailable: $e')),
        );
      }
    }
  }

  /// Speaks [text] aloud (assistant replies). Markdown is lightly stripped.
  Future<void> _speak(String text) async {
    final clean = text
        .replaceAll(RegExp(r'[*_`#>]+'), '')
        .replaceAll(RegExp(r'\[(.*?)\]\(.*?\)'), r'$1')
        .trim();
    if (clean.isEmpty) return;
    try {
      if (_voiceLocale.isNotEmpty) {
        await _tts.setLanguage(_voiceLocale.replaceAll('_', '-'));
      }
      await _tts.speak(clean);
    } catch (_) {/* TTS unavailable — silently skip */}
  }

  Future<void> _bootstrap() async {
    await _engine.start();
    _systemPrompt = await loadSystemPrompt();
    _voiceEngine = await loadVoiceEngine();
    _voiceLocale = await loadVoiceLocale();
    _corpusLocation = await loadCorpusLocation();
    _documents = await _docs.list();
    _catalog = await loadCatalog();
    final prefs = await SharedPreferences.getInstance();
    _activeModelId = prefs.getString('selected_model') ?? kDefaultModelId;
    // A previously-selected model may be gone; if so, fall back to the default
    // (downloaded automatically on first use by _prepareAndLoad below).
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
    // Persona, voice settings, documents and sideloaded models may have changed.
    _systemPrompt = await loadSystemPrompt();
    _voiceEngine = await loadVoiceEngine();
    _voiceLocale = await loadVoiceLocale();
    final docsBefore = _documents.map((d) => d.id).toSet();
    final locBefore = _corpusLocation;
    _corpusLocation = await loadCorpusLocation();
    _documents = await _docs.list();
    final docsNow = _documents.map((d) => d.id).toSet();
    // A changed corpus location closes the current index (it lives in the pack).
    if (_corpusLocation != locBefore) {
      await _indexer?.stop();
      _rag?.close();
      _rag = null;
      _embedderReady = false;
    }
    // Documents removed in Settings must be dropped from the index too.
    final removed = docsBefore.difference(docsNow);
    if (removed.isNotEmpty) {
      try {
        _rag ??= await RagIndex.open(await _docs.corpusPath());
        for (final id in removed) {
          _rag!.removeDocument(id);
        }
      } catch (_) {/* index will reconcile on next open */}
    }
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
      _tryStartAssistTurn(); // run any assist turn queued during startup
    } catch (e) {
      setState(() {
        _phase = AppPhase.error;
        _statusText = 'Failed to load model: $e';
      });
    }
  }

  Future<void> _send() async {
    var text = _input.text.trim();
    final imagePath = _pendingImagePath;
    // Allow sending an image on its own with a sensible default question.
    if (text.isEmpty && imagePath == null) return;
    if (_generating) return;
    await _tts.stop(); // don't talk over the next turn
    // Sending finalizes any in-progress dictation.
    if (_voice.isListening || _systemVoice.isListening) {
      await _voice.stop();
      await _systemVoice.stop();
      if (mounted) setState(() => _listening = false);
    }
    if (text.isEmpty && imagePath != null) text = 'What is in this image?';
    _input.clear();

    final assistant = ChatMessage('assistant', '');
    setState(() {
      _messages.add(ChatMessage('user', text, imagePath: imagePath));
      _messages.add(assistant);
      _generating = true;
      _lastStats = null;
      _pendingImagePath = null;
    });
    _scrollToBottom();

    // When documents are loaded, retrieve relevant passages and ground the
    // answer on them (RAG). The retrieved excerpts augment the system prompt.
    var systemContent = _systemPrompt;
    List<String>? sources;
    if (_documents.isNotEmpty) {
      try {
        await _ensureRag();
        // Yield the embedder to this turn; query whatever is already indexed
        // (background indexing continues afterward). Resumed in the finally.
        await _indexer?.stop();
        final qvec = (await _engine.embedBatch([text])).first;
        final hits = await _rag!
            .query(queryVec: qvec, queryText: text, topK: 4);
        if (hits.isNotEmpty) {
          final buf = StringBuffer(_systemPrompt);
          buf.writeln(
              "\n\nAnswer the user's question using ONLY the document excerpts below. "
              'Cite the source document (and page if shown). If the answer is not '
              'in them, say you could not find it in the documents.\n');
          final cited = <String>{};
          for (final h in hits) {
            buf.writeln('\n--- Source: ${h.docName}'
                '${h.page != null ? ' (page ${h.page})' : ''} ---');
            buf.writeln(h.text.trim());
            cited.add(h.page != null ? '${h.docName} (p.${h.page})' : h.docName);
          }
          systemContent = buf.toString();
          sources = cited.toList();
        }
      } catch (_) {
        // Retrieval failed (e.g. embedder unavailable) — answer without RAG.
      }
    }
    assistant.sources = sources;

    // Build the conversation: a system prompt followed by the full history
    // (excluding the still-empty assistant placeholder). A user turn that has
    // an attached image carries it in an `images` array, which the engine's
    // vision encoder reads.
    final messagesJson = jsonEncode([
      {'role': 'system', 'content': systemContent},
      ..._messages.where((m) => m != assistant).map((m) {
        final msg = <String, dynamic>{'role': m.role, 'content': m.text};
        if (m.imagePath != null) msg['images'] = [m.imagePath];
        return msg;
      }),
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
      // Speak the reply when Eva was invoked as the device assistant.
      if (_assistMode) _speak(assistant.text);
    } catch (_) {
      setState(() => _generating = false);
    }
    // The turn is done — let background indexing of the backlog continue.
    _indexer?.resume();
    _scrollToBottom();
  }

  Future<void> _newChat() async {
    if (_generating) return;
    await _engine.reset();
    setState(() {
      _messages.clear();
      _lastStats = null;
      _pendingImagePath = null;
    });
  }

  // ── Documents (RAG) ────────────────────────────────────────────────────────

  /// Lets the user attach a PDF/txt/md document, extract its text, and (re)build
  /// the retrieval index so Eva can answer questions about it.
  Future<void> _attachDocument() async {
    if (_docBusy || _generating) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: DocumentService.supportedExtensions,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    setState(() => _docBusy = true);
    try {
      final info = await _docs.addFile(path);
      _documents = await _docs.list();
      // Opening the pack starts the background indexer, which picks up this new
      // document (and resumes any interrupted ones) without blocking the UI.
      await _ensureRag();
      _indexer?.resume();
      unawaited(_indexer?.run() ?? Future.value());
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Added "${info.name}" — indexing in background.')),
        );
      }
      _maybeNudgeDocModel();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not add document: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _docBusy = false);
    }
  }

  /// Ensures the embedding model is downloaded + loaded and the RAG index for
  /// the current corpus location is open. Shows a progress dialog (the embedder
  /// download is ~200 MB the first time).
  Future<void> _ensureRag() async {
    if (_embedderReady && _rag != null) return;
    await _withProgressDialog('Setting up document search', (update) async {
      final dir = await _models.ensureInstalled(
          kEmbedderModel, (phase, p) => update(phase, p));
      update('Loading…', null);
      await _engine.loadEmbedder(dir);
      await _indexer?.stop();
      _rag?.close();
      _rag = await RagIndex.open(await _docs.corpusPath());
      _embedderReady = true;
    });
    // Start (or resume) indexing the backlog in the background — non-blocking,
    // so the chat stays usable and queries hit whatever is already indexed.
    _indexer ??= IndexingController(_docs, _engine.embedBatch)
      ..addListener(_onIndexerProgress);
    _indexer!.bind(_rag!);
    _indexer!.resume();
    unawaited(_indexer!.run());
  }

  void _onIndexerProgress() {
    if (mounted) setState(() {});
  }

  /// Suggests the stronger Qwen3 model for document Q&A when a weaker model is
  /// active (better synthesis of retrieved passages).
  void _maybeNudgeDocModel() {
    if (!mounted || _activeModelId == kDocQaModelId) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: const Text('Tip: Qwen3 1.7B gives better answers about documents.'),
      action: SnackBarAction(
        label: 'Use Qwen3',
        onPressed: () => _switchModel(kDocQaModelId),
      ),
    ));
  }

  Future<void> _switchModel(String id) async {
    if (id == _activeModelId) return;
    _activeModelId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_model', id);
    setState(() {
      _messages.clear();
      _lastStats = null;
    });
    await _prepareAndLoad();
  }

  /// Runs [work] while showing a modal progress dialog. [work] gets an updater
  /// `(phase, progress)`; progress is 0..1 or null for indeterminate.
  Future<void> _withProgressDialog(
    String title,
    Future<void> Function(void Function(String, double?)) work,
  ) async {
    if (!mounted) return;
    double? progress;
    String phase = 'Preparing…';
    StateSetter? setDlg;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (c, setState) {
          setDlg = setState;
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(phase),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  Text('${(progress! * 100).toStringAsFixed(0)}%'),
                ],
              ],
            ),
          );
        },
      ),
    );
    try {
      await work((ph, p) {
        phase = ph;
        progress = p;
        setDlg?.call(() {});
      });
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// Toggles voice input. Starts/stops the streaming recognizer, feeding the
  /// live transcript into the message field. On first use it downloads the
  /// (offline) speech model.
  Future<void> _toggleVoice() async {
    // Already listening (on either engine) → stop.
    if (_voice.isListening || _systemVoice.isListening) {
      await _voice.stop();
      await _systemVoice.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    void onText(String text) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    }

    try {
      if (_voiceEngine == VoiceEngine.system) {
        // The phone's recognizer (many languages, incl. the system language).
        await _systemVoice.start(_voiceLocale, onText, onStopped: () {
          if (mounted) setState(() => _listening = false);
        });
      } else {
        // The bundled offline English model — download it on first use.
        if (!await _ensureVoiceModel()) return;
        await _voice.start(onText);
      }
      if (mounted) setState(() => _listening = true);
    } catch (e) {
      if (mounted) {
        setState(() => _listening = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice unavailable: $e')),
        );
      }
    }
  }

  /// Ensures the speech model is present, showing a progress dialog while it
  /// downloads on first use. Returns true if the model is ready.
  Future<bool> _ensureVoiceModel() async {
    if (await _voice.isModelInstalled()) return true;
    if (!mounted) return false;
    double? progress;
    String phase = 'Preparing…';
    StateSetter? setDlg;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (c, setState) {
          setDlg = setState;
          return AlertDialog(
            title: const Text('Setting up voice'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(phase),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: progress),
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  Text('${(progress! * 100).toStringAsFixed(0)}%'),
                ],
              ],
            ),
          );
        },
      ),
    );
    var ok = false;
    try {
      await _voice.ensureModel((ph, p) {
        phase = ph;
        progress = p;
        setDlg?.call(() {});
      });
      await _voice.load();
      ok = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice setup failed: $e')),
        );
      }
    }
    if (mounted) Navigator.of(context).pop(); // close the progress dialog
    return ok;
  }

  /// Lets the user attach a photo (camera or gallery) to the next message.
  Future<void> _attachImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
      );
      if (picked != null) {
        setState(() => _pendingImagePath = picked.path);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not get image: $e')),
        );
      }
    }
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
        title: const Text('Eva'),
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
        bottom: _indexingBanner(),
      ),
      body: switch (_phase) {
        AppPhase.ready => _buildChat(),
        AppPhase.error => _buildError(),
        _ => _buildLoading(),
      },
    );
  }

  /// A thin progress strip shown under the AppBar while the background indexer
  /// is working through the document backlog (null = nothing to show).
  PreferredSizeWidget? _indexingBanner() {
    final ix = _indexer;
    if (ix == null || !ix.isIndexing || ix.pending <= 0) return null;
    final label = ix.currentName == null
        ? 'Indexing ${ix.pending} document${ix.pending == 1 ? '' : 's'}…'
        : 'Indexing "${ix.currentName}" — ${ix.pending} left';
    return PreferredSize(
      preferredSize: const Size.fromHeight(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(label, style: const TextStyle(fontSize: 11)),
            ),
          ),
        ],
      ),
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
        if (_pendingImagePath != null) _pendingImagePreview(),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Attach a document',
                onPressed: (_generating || _docBusy) ? null : _attachDocument,
                icon: _docBusy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _documents.isEmpty
                        ? const Icon(Icons.attach_file)
                        : Badge(
                            label: Text('${_documents.length}'),
                            child: const Icon(Icons.attach_file),
                          ),
              ),
              if (_visionActive)
                IconButton(
                  tooltip: 'Attach a photo',
                  onPressed: _generating ? null : _attachImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
              IconButton(
                tooltip: _listening ? 'Stop listening' : 'Speak',
                onPressed: _generating ? null : _toggleVoice,
                color: _listening ? Theme.of(context).colorScheme.error : null,
                icon: Icon(_listening ? Icons.mic : Icons.mic_none),
              ),
              Expanded(
                child: TextField(
                  controller: _input,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: _visionActive ? 'Message or ask about a photo' : 'Message',
                    border: const OutlineInputBorder(),
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

  Widget _pendingImagePreview() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_pendingImagePath!),
              width: 56,
              height: 56,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Text('Photo attached')),
          IconButton(
            tooltip: 'Remove photo',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() => _pendingImagePath = null),
          ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessage m) {
    final isUser = m.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    final bubble = Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.72,
      ),
      decoration: BoxDecoration(
        color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      // User text is shown verbatim (with any attached photo above it);
      // assistant replies are rendered as markdown (bold, italics, lists, …).
      child: isUser
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (m.imagePath != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(
                        File(m.imagePath!),
                        width: 180,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                if (m.text.isNotEmpty) Text(m.text),
              ],
            )
          : m.text.isEmpty
              ? const Text('…')
              : MarkdownBody(
                  data: m.text,
                  shrinkWrap: true,
                  styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                      .copyWith(p: Theme.of(context).textTheme.bodyMedium),
                ),
    );

    if (isUser) {
      return Align(alignment: Alignment.centerRight, child: bubble);
    }
    // Assistant messages show Eva's avatar, like a chat with her.
    final sources = m.sources;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4, right: 8),
          child: CircleAvatar(
            radius: 18,
            backgroundImage: AssetImage('assets/eva.png'),
          ),
        ),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              bubble,
              if (sources != null && sources.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6, top: 2, bottom: 4),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: -8,
                    children: [
                      for (final s in sources)
                        Chip(
                          avatar: const Icon(Icons.description_outlined, size: 14),
                          label: Text(s, style: const TextStyle(fontSize: 11)),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
