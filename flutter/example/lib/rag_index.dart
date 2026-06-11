import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'corpus_db.dart';
import 'usearch.dart';

/// Matryoshka target dimension: nomic-embed supports truncating its 768-dim
/// output to a shorter prefix with little quality loss. Combined with usearch
/// int8 quantization this is ~6x smaller than f16/768 — the lever that makes a
/// very large archive fit on an SD card.
const int kTargetDim = 256;

/// On-disk vector format marker (bump when dim/quantization scheme changes so
/// old packs are rebuilt rather than mis-read).
const int kPackFormat = 2;

/// Embeds a batch of texts into unit-norm vectors (wired to the worker isolate).
typedef EmbedBatch = Future<List<Float32List>> Function(List<String> texts);

/// On-device hybrid retrieval index for documents: a usearch HNSW vector index
/// (semantic) fused with SQLite FTS5 (keyword/BM25) via Reciprocal Rank Fusion.
/// Both live inside the corpus pack so they travel with the storage location.
class RagIndex {
  RagIndex._(this._packDir, this._db, this._vec, this._dim);

  final String _packDir;
  final CorpusDb _db;
  UsearchIndex? _vec;
  int _dim;

  String get _vecPath => '$_packDir/vectors.usearch';
  String get _metaPath => '$_packDir/vectors.meta';

  int get documentCount => _db.documentCount;
  int get chunkCount => _db.chunkCount;
  int get vectorCount => _vec?.length ?? 0;
  bool get isEmpty => _db.chunkCount == 0;

  /// Opens (or creates) the pack at [packDir], loading the vector index if one
  /// has already been built.
  static Future<RagIndex> open(String packDir) async {
    await Directory(packDir).create(recursive: true);
    final db = CorpusDb.open('$packDir/catalog.sqlite');
    final metaFile = File('$packDir/vectors.meta');
    final vecFile = File('$packDir/vectors.usearch');
    UsearchIndex? vec;
    var dim = 0;
    if (await metaFile.exists() && await vecFile.exists()) {
      try {
        final meta = jsonDecode(await metaFile.readAsString())
            as Map<String, dynamic>;
        // Only reuse vectors written by the current format; otherwise leave the
        // index empty and force a rebuild (self-heal re-indexes the documents).
        if ((meta['format'] as num?)?.toInt() == kPackFormat) {
          dim = (meta['dim'] as num).toInt();
          vec = UsearchIndex.loadFile(vecFile.path, dim);
        } else {
          db.resetIndexed();
        }
      } catch (_) {
        vec = null;
        dim = 0;
      }
    }
    return RagIndex._(packDir, db, vec, dim);
  }

  /// Chunks [fullText], embeds each chunk and adds it to both indexes, then
  /// persists them. [onProgress] reports 0..1 over the embedding work.
  Future<void> addDocument({
    required String docId,
    required String name,
    required String fullText,
    required EmbedBatch embed,
    void Function(double progress)? onProgress,
  }) async {
    final chunks = _chunk(fullText);
    if (chunks.isEmpty) return;

    // Idempotent: clear any partial chunks from an interrupted earlier run,
    // then (re)insert the document marked not-yet-indexed.
    _db.removeDocument(docId);
    _db.upsertDocument(docId, name, fullText.length,
        DateTime.now().toIso8601String());

    const batchSize = 16;
    var done = 0;
    for (var i = 0; i < chunks.length; i += batchSize) {
      final batch = chunks.sublist(i, (i + batchSize).clamp(0, chunks.length));
      final vectors = await embed([for (final c in batch) c.text]);

      // Lazily size the vector index from the first embedding (Matryoshka).
      if (_vec == null) {
        _dim = math.min(kTargetDim, vectors.first.length);
        _vec = UsearchIndex.create(_dim, capacity: chunks.length);
      }
      _vec!.reserve(_vec!.length + batch.length);

      _db.beginTransaction();
      for (var j = 0; j < batch.length; j++) {
        final id = _db.insertChunk(docId, batch[j].page, batch[j].text);
        _vec!.add(id, _toDim(vectors[j], _dim));
      }
      _db.commit();

      done += batch.length;
      onProgress?.call(done / chunks.length);
    }
    await _persist();
    _db.markIndexed(docId); // only after vectors are safely saved
  }

  /// Ids of documents that have finished indexing in this pack.
  Set<String> get indexedDocIds => _db.indexedDocIds();

  Future<void> _persist() async {
    if (_vec == null) return;
    _vec!.save(_vecPath);
    await File(_metaPath)
        .writeAsString(jsonEncode({'dim': _dim, 'format': kPackFormat}));
  }

  /// Truncates [v] to [dim] (Matryoshka) and renormalizes to unit length so
  /// cosine distance stays meaningful.
  Float32List _toDim(Float32List v, int dim) {
    final d = v.length <= dim ? v.length : dim;
    final out = Float32List(d);
    var norm = 0.0;
    for (var i = 0; i < d; i++) {
      out[i] = v[i];
      norm += v[i] * v[i];
    }
    if (norm > 0) {
      final inv = 1.0 / math.sqrt(norm);
      for (var i = 0; i < d; i++) {
        out[i] *= inv;
      }
    }
    return out;
  }

  /// Hybrid retrieval: semantic (usearch) ⊕ keyword (FTS5), fused with RRF.
  /// Returns the top-[topK] chunks, best first.
  Future<List<ChunkHit>> query({
    required Float32List queryVec,
    required String queryText,
    int topK = 4,
    int candidates = 20,
  }) async {
    final ranks = <int, double>{};
    const rrfK = 60.0;
    const embWeight = 1.0;
    const ftsWeight = 0.5;

    // Semantic candidates (already distance-sorted, best first). Truncate the
    // query to the pack's dimension to match the indexed vectors.
    if (_vec != null && _vec!.length > 0) {
      final hits = _vec!.search(_toDim(queryVec, _dim), candidates);
      for (var r = 0; r < hits.length; r++) {
        ranks.update(hits[r].key, (v) => v + embWeight / (rrfK + r),
            ifAbsent: () => embWeight / (rrfK + r));
      }
    }
    // Keyword candidates (bm25-sorted, best first).
    final fts = _db.ftsSearch(queryText, candidates);
    for (var r = 0; r < fts.length; r++) {
      ranks.update(fts[r].key, (v) => v + ftsWeight / (rrfK + r),
          ifAbsent: () => ftsWeight / (rrfK + r));
    }
    if (ranks.isEmpty) return const [];

    final ordered = ranks.keys.toList()
      ..sort((a, b) => ranks[b]!.compareTo(ranks[a]!));
    final top = ordered.take(topK).toList();
    return _db.fetchChunks(top); // deleted chunks resolve to nothing → skipped
  }

  /// Removes a document's chunks from the catalog. Its vectors stay in the
  /// usearch index as orphans (filtered out at fetch); a future compaction can
  /// rebuild to reclaim space.
  void removeDocument(String docId) => _db.removeDocument(docId);

  void close() {
    _vec?.close();
    _db.close();
  }

  // ── Chunking ───────────────────────────────────────────────────────────────

  /// Splits text into overlapping chunks, tracking the current `[Page N]` marker
  /// (inserted during PDF extraction) for citations.
  List<({int? page, String text})> _chunk(String text,
      {int maxChars = 900, int overlapChars = 150}) {
    final out = <({int? page, String text})>[];
    final pageRe = RegExp(r'^\s*\[Page (\d+)\]\s*$');
    int? page;
    final buf = StringBuffer();

    void flush() {
      final s = buf.toString().trim();
      if (s.length >= 8) out.add((page: page, text: s));
      buf.clear();
    }

    for (final line in const LineSplitter().convert(text)) {
      final m = pageRe.firstMatch(line);
      if (m != null) {
        page = int.tryParse(m.group(1)!);
        continue;
      }
      if (buf.length + line.length + 1 > maxChars && buf.isNotEmpty) {
        final full = buf.toString();
        flush();
        // Carry an overlap tail into the next chunk for context continuity.
        if (overlapChars > 0 && full.length > overlapChars) {
          buf.write(full.substring(full.length - overlapChars));
          buf.write('\n');
        }
      }
      buf.write(line);
      buf.write('\n');
    }
    flush();
    return out;
  }
}
