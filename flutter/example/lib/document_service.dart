import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A document the user added for question-answering.
class DocumentInfo {
  DocumentInfo({required this.id, required this.name, required this.chars});
  final String id; // corpus filename stem
  final String name; // original filename shown to the user
  final int chars; // extracted character count

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'chars': chars};
  static DocumentInfo fromJson(Map<String, dynamic> j) => DocumentInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        chars: (j['chars'] as num).toInt(),
      );
}

/// Manages the on-device document corpus that the RAG embedder indexes.
///
/// Extracted plain text for each document is written as `<id>.txt` into a
/// single corpus directory; the Cactus engine builds its hybrid (embedding +
/// BM25) index over that directory. A small `_docs.json` tracks the original
/// filenames so the UI can list and remove documents.
class DocumentService {
  static const List<String> supportedExtensions = ['pdf', 'txt', 'md', 'text'];

  Future<Directory> corpusDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/corpus');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> corpusPath() async => (await corpusDir()).path;

  Future<File> _metaFile() async => File('${await corpusPath()}/_docs.json');

  Future<List<DocumentInfo>> list() async {
    final f = await _metaFile();
    if (!await f.exists()) return [];
    try {
      final raw = jsonDecode(await f.readAsString()) as List;
      return raw
          .map((e) => DocumentInfo.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> get hasDocuments async => (await list()).isNotEmpty;

  Future<void> _saveList(List<DocumentInfo> docs) async {
    final f = await _metaFile();
    await f.writeAsString(jsonEncode(docs.map((d) => d.toJson()).toList()));
  }

  /// Extracts text from [filePath] (PDF/txt/md), stores it in the corpus, and
  /// records it. Returns the new document's info. Throws if no text could be
  /// extracted (e.g. a scanned/image-only PDF).
  Future<DocumentInfo> addFile(String filePath) async {
    final name = filePath.split(Platform.pathSeparator).last;
    final lower = name.toLowerCase();
    final String text;
    if (lower.endsWith('.pdf')) {
      final bytes = await File(filePath).readAsBytes();
      text = await Isolate.run(() => _extractPdfText(bytes));
    } else {
      text = await File(filePath).readAsString();
    }
    if (text.trim().length < 8) {
      throw Exception(
          'No selectable text found (a scanned/image PDF needs OCR, not yet supported).');
    }

    final id = _uniqueId(name, await list());
    await File('${await corpusPath()}/$id.txt').writeAsString(text);
    final info = DocumentInfo(id: id, name: name, chars: text.length);
    final docs = await list()..add(info);
    await _saveList(docs);
    return info;
  }

  Future<void> remove(String id) async {
    final f = File('${await corpusPath()}/$id.txt');
    if (await f.exists()) await f.delete();
    final docs = (await list()).where((d) => d.id != id).toList();
    await _saveList(docs);
    // Drop the cached index so it rebuilds without the removed document.
    await _clearIndexCache();
  }

  Future<void> clearAll() async {
    final dir = await corpusDir();
    if (await dir.exists()) {
      await for (final e in dir.list()) {
        if (e is File) await e.delete();
      }
    }
  }

  /// Forces the corpus index to rebuild on next load (after docs change).
  Future<void> invalidateIndex() => _clearIndexCache();

  /// Removes the engine's cached corpus index so it is rebuilt next load.
  Future<void> _clearIndexCache() async {
    final dir = await corpusPath();
    for (final n in ['index.bin', 'data.bin']) {
      final f = File('$dir/$n');
      if (await f.exists()) await f.delete();
    }
  }

  String _uniqueId(String name, List<DocumentInfo> existing) {
    final base = name
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final taken = existing.map((d) => d.id).toSet();
    var id = base.isEmpty ? 'doc' : base;
    var n = 1;
    while (taken.contains(id)) {
      id = '${base}_$n';
      n++;
    }
    return id;
  }
}

/// Extracts text from PDF [bytes], inserting `[Page N]` markers so retrieved
/// chunks carry page context for citations. Runs in a background isolate.
String _extractPdfText(List<int> bytes) {
  final doc = PdfDocument(inputBytes: bytes);
  final extractor = PdfTextExtractor(doc);
  final buf = StringBuffer();
  try {
    final count = doc.pages.count;
    for (var i = 0; i < count; i++) {
      final pageText =
          extractor.extractText(startPageIndex: i, endPageIndex: i).trim();
      if (pageText.isNotEmpty) {
        buf.writeln('\n[Page ${i + 1}]');
        buf.writeln(pageText);
      }
    }
  } finally {
    doc.dispose();
  }
  return buf.toString();
}
