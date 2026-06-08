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
      toMain.send({
        'type': cmd == 'init' ? 'init_error' : 'complete_error',
        'message': e.toString(),
      });
    }
  });
}
