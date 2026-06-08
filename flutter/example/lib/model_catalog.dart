import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A selectable on-device model. Cactus can only load *pre-transpiled* bundles
/// (config.txt + weights + components/manifest.json), so every entry points at a
/// bundle we produce in CI (embedded or downloaded) or one the user sideloads
/// from a folder on the device.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.sizeLabel,
    this.asset,
    this.url,
    this.localPath,
  }) : assert(asset != null || url != null || localPath != null,
            'a model must come from an asset, a URL, or a local path');

  /// Stable id; also the on-device directory name under `models/<id>/`
  /// (download/asset models only).
  final String id;
  final String name;
  final String sizeLabel;

  /// Flutter asset path for a bundle embedded in the APK (the default model).
  final String? asset;

  /// URL of a pre-transpiled bundle zip (downloaded on demand).
  final String? url;

  /// Absolute path to an already-extracted model directory (sideloaded).
  final String? localPath;

  bool get isBundled => asset != null;
  bool get isSideloaded => localPath != null;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'sizeLabel': sizeLabel, 'localPath': localPath};

  static ModelSpec fromJson(Map<String, dynamic> j) => ModelSpec(
        id: j['id'] as String,
        name: j['name'] as String,
        sizeLabel: j['sizeLabel'] as String,
        localPath: j['localPath'] as String?,
      );
}

/// Built-in models. The default is embedded in the APK so the app works offline
/// out of the box; larger models are downloaded from the GitHub release.
const List<ModelSpec> kBuiltinCatalog = [
  ModelSpec(
    id: 'lfm2.5-350m-int4',
    name: 'LFM2.5 350M (default)',
    sizeLabel: 'bundled',
    asset: 'assets/model.zip',
  ),
  ModelSpec(
    id: 'qwen3-1.7b-int4',
    name: 'Qwen3 1.7B',
    sizeLabel: '~1.1 GB download',
    url: 'https://github.com/maxbrito500/cactus/releases/latest/download/qwen3-1.7b-int4-bundle.zip',
  ),
];

const String kDefaultModelId = 'lfm2.5-350m-int4';

const String _kSideloadKey = 'sideloaded_models';

/// Sideloaded models the user added from a folder, persisted across launches.
Future<List<ModelSpec>> loadSideloadedModels() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_kSideloadKey) ?? [];
  return raw
      .map((s) => ModelSpec.fromJson(jsonDecode(s) as Map<String, dynamic>))
      .toList();
}

Future<void> saveSideloadedModels(List<ModelSpec> models) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
    _kSideloadKey,
    models.map((m) => jsonEncode(m.toJson())).toList(),
  );
}

/// The full catalog = built-ins + sideloaded.
Future<List<ModelSpec>> loadCatalog() async =>
    [...kBuiltinCatalog, ...await loadSideloadedModels()];

ModelSpec modelById(List<ModelSpec> catalog, String id) =>
    catalog.firstWhere((m) => m.id == id, orElse: () => kBuiltinCatalog.first);
