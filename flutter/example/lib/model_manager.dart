import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// The transpiled model bundle is shipped inside the APK as an asset and
/// unpacked to internal storage on first launch. (Cactus models must be
/// transpiled on a host before they are loadable; the device cannot do it,
/// so we ship a ready-to-load bundle.)
const String kModelAsset = 'assets/model.zip';
const String kModelName = 'lfm2.5-350m-int4';

/// Files `cactus_init` requires in the model directory. The transpiled graph
/// lives under components/manifest.json; raw weights + tokenizer sit at root.
const List<String> _requiredFiles = [
  'config.txt',
  'token_embeddings.weights',
  'vocab.txt',
  'tokenizer_config.txt',
  'components/manifest.json',
];

/// Reports unpack progress. [progress] is null during the indeterminate phases.
typedef ProgressCallback = void Function(String phase, double? progress);

class ModelManager {
  Future<Directory> _modelDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/models/$kModelName');
  }

  Future<bool> _isValid(Directory dir) async {
    if (!await dir.exists()) return false;
    for (final name in _requiredFiles) {
      if (!await File('${dir.path}/$name').exists()) return false;
    }
    return true;
  }

  /// Returns the model directory path if a valid model is already unpacked.
  Future<String?> existingModelPath() async {
    final dir = await _modelDir();
    return await _isValid(dir) ? dir.path : null;
  }

  /// Ensures the bundled model is unpacked, returning its directory.
  /// No-ops if already present.
  Future<String> ensureModel(ProgressCallback onProgress) async {
    final modelDir = await _modelDir();
    if (await _isValid(modelDir)) return modelDir.path;

    onProgress('Preparing model…', null);
    // Copy the asset zip out of the APK to a temp file.
    final tmp = await getTemporaryDirectory();
    final zipPath = '${tmp.path}/$kModelName.zip';
    final data = await rootBundle.load(kModelAsset);
    await File(zipPath).writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );

    onProgress('Unpacking model…', null);
    await Isolate.run(() => _extractZip(zipPath, modelDir.path));
    _promoteSingleRoot(modelDir);

    if (!await _isValid(modelDir)) {
      throw Exception('Model bundle is missing required files after unpacking.');
    }
    try {
      await File(zipPath).delete();
    } catch (_) {}
    return modelDir.path;
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
