/// A selectable on-device model. Cactus can only load *pre-transpiled* bundles
/// (config.txt + weights + components/manifest.json), so every entry points at a
/// bundle we produce in CI — either embedded in the APK or downloaded on demand.
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.sizeLabel,
    this.asset,
    this.url,
  }) : assert(asset != null || url != null,
            'a model must come from a bundled asset or a URL');

  /// Stable id; also the on-device directory name under `models/<id>/`.
  final String id;
  final String name;
  final String sizeLabel;

  /// Flutter asset path for a bundle embedded in the APK (the default model).
  final String? asset;

  /// URL of a pre-transpiled bundle zip (downloaded on demand).
  final String? url;

  bool get isBundled => asset != null;
}

/// The default model is embedded in the APK so the app works offline out of the
/// box. Larger models are downloaded from the GitHub release on demand.
const List<ModelSpec> kModelCatalog = [
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

ModelSpec modelById(String id) =>
    kModelCatalog.firstWhere((m) => m.id == id,
        orElse: () => kModelCatalog.first);
