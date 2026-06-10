import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'cactus.dart' as cactus;

/// Drives the native Cactus model from a dedicated worker isolate.
///
/// All FFI calls (`cactus_init`, `cactus_complete`) block the calling thread,
/// so they must not run on the UI isolate — otherwise the app would freeze
/// (and ANR) while a model loads or generates. This class owns a long-lived
/// worker isolate that holds the model pointer and streams tokens back.
class InferenceEngine {
  final ReceivePort _fromWorker = ReceivePort();
  final Completer<void> _ready = Completer<void>();
  late SendPort _toWorker;

  Completer<void>? _initCompleter;
  Completer<void>? _resetCompleter;
  Completer<void>? _corpusCompleter;
  Completer<String>? _ragCompleter;
  StreamController<String>? _tokenController;
  Completer<Map<String, dynamic>>? _doneCompleter;

  bool get isBusy => _tokenController != null;

  Future<void> start() async {
    _fromWorker.listen(_onMessage);
    await Isolate.spawn(_workerMain, _fromWorker.sendPort);
    await _ready.future;
  }

  void _onMessage(dynamic msg) {
    if (msg is SendPort) {
      _toWorker = msg;
      _ready.complete();
      return;
    }
    final m = msg as Map;
    switch (m['type'] as String) {
      case 'init_done':
        _initCompleter?.complete();
        _initCompleter = null;
        break;
      case 'init_error':
        _initCompleter?.completeError(Exception(m['message']));
        _initCompleter = null;
        break;
      case 'reset_done':
        _resetCompleter?.complete();
        _resetCompleter = null;
        break;
      case 'corpus_done':
        _corpusCompleter?.complete();
        _corpusCompleter = null;
        break;
      case 'corpus_error':
        _corpusCompleter?.completeError(Exception(m['message']));
        _corpusCompleter = null;
        break;
      case 'rag_result':
        _ragCompleter?.complete(m['result'] as String);
        _ragCompleter = null;
        break;
      case 'rag_error':
        _ragCompleter?.completeError(Exception(m['message']));
        _ragCompleter = null;
        break;
      case 'token':
        _tokenController?.add(m['text'] as String);
        break;
      case 'complete_done':
        _doneCompleter?.complete(Map<String, dynamic>.from(m['result'] as Map));
        _tokenController?.close();
        _tokenController = null;
        _doneCompleter = null;
        break;
      case 'complete_error':
        final err = Exception(m['message']);
        _tokenController?.addError(err);
        _tokenController?.close();
        _tokenController = null;
        _doneCompleter?.completeError(err);
        _doneCompleter = null;
        break;
    }
  }

  /// Loads the model from a directory of converted weights with the given
  /// KV-cache context window (in tokens).
  Future<void> initModel(String modelDir, {int contextSize = 4096}) {
    _initCompleter = Completer<void>();
    _toWorker.send({
      'cmd': 'init',
      'modelDir': modelDir,
      'contextSize': contextSize,
    });
    return _initCompleter!.future;
  }

  /// Clears the conversation KV cache (starts a fresh conversation).
  Future<void> reset() {
    _resetCompleter = Completer<void>();
    _toWorker.send({'cmd': 'reset'});
    return _resetCompleter!.future;
  }

  /// Loads the embedding model from [embedderDir] and builds/loads the hybrid
  /// retrieval index over the `.txt`/`.md` files in [corpusDir]. Held alongside
  /// the chat model. Call again to rebuild after documents change.
  Future<void> initCorpus(String embedderDir, String corpusDir) {
    _corpusCompleter = Completer<void>();
    _toWorker.send({
      'cmd': 'init_corpus',
      'embedderDir': embedderDir,
      'corpusDir': corpusDir,
    });
    return _corpusCompleter!.future;
  }

  /// Frees the embedding model and its index (e.g. when no documents remain).
  Future<void> freeEmbedder() {
    _corpusCompleter = Completer<void>();
    _toWorker.send({'cmd': 'free_embedder'});
    return _corpusCompleter!.future;
  }

  /// Retrieves the top-[topK] document passages for [query] using the engine's
  /// hybrid (embedding + BM25) RAG. Returns the raw JSON
  /// (`{"chunks":[{"score","source","content"}]}`).
  Future<String> ragQuery(String query, {int topK = 4}) {
    _ragCompleter = Completer<String>();
    _toWorker.send({'cmd': 'rag_query', 'query': query, 'topK': topK});
    return _ragCompleter!.future;
  }

  /// Runs a chat completion. [messagesJson] is a JSON array of
  /// `{"role":..., "content":...}`. The returned `tokens` stream emits each
  /// generated token as it arrives; `stats` completes with the parsed result
  /// JSON (`response`, `decode_tps`, …) when generation finishes.
  ({Stream<String> tokens, Future<Map<String, dynamic>> stats}) complete(
    String messagesJson, {
    String? optionsJson,
  }) {
    _tokenController = StreamController<String>();
    _doneCompleter = Completer<Map<String, dynamic>>();
    _toWorker.send({
      'cmd': 'complete',
      'messages': messagesJson,
      'options': optionsJson,
    });
    return (tokens: _tokenController!.stream, stats: _doneCompleter!.future);
  }
}

void _workerMain(SendPort toMain) {
  final port = ReceivePort();
  toMain.send(port.sendPort);

  cactus.CactusModelT? model;
  cactus.CactusModelT? embedder; // dedicated embedding model for document RAG

  port.listen((msg) {
    final m = msg as Map;
    final cmd = m['cmd'] as String;
    try {
      switch (cmd) {
        case 'init':
          // Destroy any currently-loaded model so this also handles switching.
          final existing = model;
          if (existing != null) {
            cactus.cactusDestroy(existing);
            model = null;
          }
          model = cactus.cactusInitWithContext(
            m['modelDir'] as String,
            null,
            false,
            m['contextSize'] as int,
          );
          toMain.send({'type': 'init_done'});
          break;
        case 'reset':
          final handle = model;
          if (handle != null) cactus.cactusReset(handle);
          toMain.send({'type': 'reset_done'});
          break;
        case 'init_corpus':
          // (Re)load the embedder and build/load the hybrid index over the
          // corpus directory. cacheIndex=true persists index.bin across launches.
          final existing = embedder;
          if (existing != null) {
            cactus.cactusDestroy(existing);
            embedder = null;
          }
          embedder = cactus.cactusInit(
            m['embedderDir'] as String,
            m['corpusDir'] as String,
            true,
          );
          toMain.send({'type': 'corpus_done'});
          break;
        case 'free_embedder':
          final handle = embedder;
          if (handle != null) {
            cactus.cactusDestroy(handle);
            embedder = null;
          }
          toMain.send({'type': 'corpus_done'});
          break;
        case 'rag_query':
          final handle = embedder;
          if (handle == null) {
            toMain.send({'type': 'rag_error', 'message': 'Corpus not initialized'});
            break;
          }
          final ragResult = cactus.cactusRagQuery(
            handle,
            m['query'] as String,
            m['topK'] as int,
          );
          toMain.send({'type': 'rag_result', 'result': ragResult});
          break;
        case 'complete':
          final handle = model;
          if (handle == null) {
            toMain.send({'type': 'complete_error', 'message': 'Model not initialized'});
            break;
          }
          final result = cactus.cactusComplete(
            handle,
            m['messages'] as String,
            m['options'] as String?,
            null,
            (token, _) => toMain.send({'type': 'token', 'text': token}),
          );
          Map<String, dynamic> parsed;
          try {
            parsed = jsonDecode(result) as Map<String, dynamic>;
          } catch (_) {
            parsed = {'response': result};
          }
          toMain.send({'type': 'complete_done', 'result': parsed});
          break;
      }
    } catch (e) {
      final errorType = switch (cmd) {
        'init' => 'init_error',
        'init_corpus' || 'free_embedder' => 'corpus_error',
        'rag_query' => 'rag_error',
        _ => 'complete_error',
      };
      toMain.send({'type': errorType, 'message': e.toString()});
    }
  });
}
