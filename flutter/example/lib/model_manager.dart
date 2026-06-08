import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

/// Files `cactus_init` requires in a model directory. The transpiled graph lives
/// under components/manifest.json; raw weights + tokenizer sit at root.
const List<String> _requiredFiles = [
  'config.txt',
  'token_embeddings.weights',
  'vocab.txt',
  'tokenizer_config.txt',
  'components/manifest.json',
];

/// Reports install progress. [progress] is 0..1 during download, null during
/// the indeterminate unpack/copy phases.
typedef ProgressCallback = void Function(String phase, double? progress);

class ModelManager {
  Future<Directory> _modelDir(String id) async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/models/$id');
  }

  Future<bool> _isValid(Directory dir) async {
    if (!await dir.exists()) return false;
    for (final name in _requiredFiles) {
      if (!await File('${dir.path}/$name').exists()) return false;
    }
    return true;
  }

  /// Whether a usable copy of [spec] is already on disk.
  Future<bool> isInstalled(ModelSpec spec) async =>
      _isValid(await _modelDir(spec.id));

  /// Returns the model directory if installed, else null.
  Future<String?> installedPath(ModelSpec spec) async {
    final dir = await _modelDir(spec.id);
    return await _isValid(dir) ? dir.path : null;
  }

  /// Ensures [spec] is installed (unpacking the bundled asset or downloading the
  /// bundle), returning its directory. No-ops if already present.
  Future<String> ensureInstalled(ModelSpec spec, ProgressCallback onProgress) async {
    final modelDir = await _modelDir(spec.id);
    if (await _isValid(modelDir)) return modelDir.path;

    final tmp = await getTemporaryDirectory();
    final zipPath = '${tmp.path}/${spec.id}.zip';

    if (spec.isBundled) {
      onProgress('Preparing model…', null);
      final data = await rootBundle.load(spec.asset!);
      await File(zipPath).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    } else {
      await _download(spec.url!, zipPath, onProgress);
    }

    onProgress('Unpacking…', null);
    await Isolate.run(() => _extractZip(zipPath, modelDir.path));
    _promoteSingleRoot(modelDir);

    if (!await _isValid(modelDir)) {
      // Leave no half-extracted directory behind.
      try {
        await modelDir.delete(recursive: true);
      } catch (_) {}
      throw Exception('Model bundle is missing required files after unpacking.');
    }
    try {
      await File(zipPath).delete();
    } catch (_) {}
    return modelDir.path;
  }

  Future<void> _download(String url, String zipPath, ProgressCallback onProgress) async {
    onProgress('Downloading…', 0);
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) {
        throw Exception('Download failed: HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? 0;
      var received = 0;
      final sink = File(zipPath).openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress('Downloading…', received / total);
      }
      await sink.close();
    } finally {
      client.close();
    }
  }
}

/// Runs inside an `Isolate.run` — extracts the zip to [outDirPath].
void _extractZip(String zipPath, String outDirPath) {
  final bytes = File(zipPath).readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);
  final outDir = Directory(outDirPath)..createSync(recursive: true);
  for (final entry in archive) {
    final outPath = '${outDir.path}/${entry.name}';
    if (entry.isFile) {
      File(outPath)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entry.content as List<int>);
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }
}

/// If the archive wrapped everything in one top-level directory, hoist its
/// contents up so `config.txt` sits at the model-dir root.
void _promoteSingleRoot(Directory outDir) {
  if (File('${outDir.path}/config.txt').existsSync()) return;
  final children = outDir
      .listSync()
      .where((e) => e.path.split(Platform.pathSeparator).last != '__MACOSX')
      .toList();
  if (children.length != 1 || children.first is! Directory) return;
  final nested = children.first as Directory;
  if (!File('${nested.path}/config.txt').existsSync()) return;
  for (final child in nested.listSync()) {
    final name = child.path.split(Platform.pathSeparator).last;
    child.renameSync('${outDir.path}/$name');
  }
  nested.deleteSync();
}
