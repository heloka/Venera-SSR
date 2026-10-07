import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'upscale_models.dart';
import 'upscale_status_tracker.dart';

const _bundleVersion = '20220728';
const _bundleSha256 =
    'c6e08d46c11704b1e3a1ada9ddd591cb5005f52f132136c8633ba25def400e01';

@immutable
class UpscaleConfig {
  const UpscaleConfig({
    this.enabled = true,
    this.modelId = 'real-cugan-se',
    this.scale = 2,
    this.denoise = -1,
    this.tta = false,
    this.syncgap = 3,
    this.tileSize = 0,
    this.mixRatio = 100,
    this.gpuId = 0,
    this.maxInputEdge = 0,
    this.preloadPages = 8,
    this.legacyModelId = 'anime4k_x4',
  });

  final bool enabled;
  final String modelId;
  final int scale;
  final int denoise;
  final bool tta;
  final int syncgap;
  final int tileSize;
  final int mixRatio;
  final int gpuId;
  final int maxInputEdge;
  final int preloadPages;
  final String legacyModelId;

  factory UpscaleConfig.fromLegacy({
    required bool enabled,
    String? modelId,
    int? maxInputEdge,
    int? scale,
  }) {
    final legacyModel = modelId != null &&
            UpscaleModels.all.any((model) => model.id == modelId)
        ? modelId
        : 'anime4k_x4';
    return UpscaleConfig.fromJson(UpscaleConfig(
      enabled: enabled,
      legacyModelId: legacyModel,
      maxInputEdge: (maxInputEdge ?? 0).clamp(0, 32768).toInt(),
      scale: scale ?? 2,
    ).toJson());
  }

  bool get isLegacy => modelId.startsWith('legacy:');
  String get selectedModelId => isLegacy ? modelId.substring(7) : modelId;
  bool get isPro => selectedModelId == 'real-cugan-pro';
  String get displayModel => isLegacy
      ? selectedModelId
      : isPro
      ? 'Real-CUGAN Pro'
      : 'Real-CUGAN SE';

  List<int> get supportedScales => isLegacy
      ? switch (selectedModelId) {
          'anime4k_x4' || 'general_x4v3' || 'realesr-animevideov3' => [2, 3, 4],
          _ => [2],
        }
      : isPro
      ? const [2, 3]
      : const [2, 3, 4];

  List<int> get supportedDenoise => isLegacy
      ? const [-1]
      : isPro || scale >= 3
      ? const [-1, 0, 3]
      : const [-1, 0, 1, 2, 3];

  String get id =>
      sha256.convert(utf8.encode(jsonEncode(cacheConfig))).toString();

  Map<String, Object?> get cacheConfig => {
    'modelId': modelId,
    'scale': scale,
    'denoise': denoise,
    'tta': tta,
    'syncgap': syncgap,
    'tileSize': tileSize,
    'mixRatio': mixRatio,
    'gpuId': gpuId,
    'maxInputEdge': maxInputEdge,
  };

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'modelId': modelId,
    'scale': scale,
    'denoise': denoise,
    'tta': tta,
    'syncgap': syncgap,
    'tileSize': tileSize,
    'mixRatio': mixRatio,
    'gpuId': gpuId,
    'maxInputEdge': maxInputEdge,
    'preloadPages': preloadPages,
    'legacyModelId': legacyModelId,
  };

  factory UpscaleConfig.fromJson(Object? json, {UpscaleConfig? fallback}) {
    final defaults = fallback ?? const UpscaleConfig();
    final values = json is Map ? json : const {};
    int number(String key, int original) =>
        values[key] is num ? (values[key] as num).toInt() : original;
    final requestedModel = values['modelId'] is String
        ? values['modelId'] as String
        : defaults.modelId;
    final validModel =
        const {'real-cugan-se', 'real-cugan-pro'}.contains(requestedModel) ||
        (requestedModel.startsWith('legacy:') &&
            UpscaleModels.all.any(
              (model) => model.id == requestedModel.substring(7),
            ));
    final config = UpscaleConfig(
      enabled: values['enabled'] is bool
          ? values['enabled'] as bool
          : defaults.enabled,
      modelId: validModel ? requestedModel : defaults.modelId,
      scale: number('scale', defaults.scale),
      denoise: number('denoise', defaults.denoise),
      tta: values['tta'] is bool ? values['tta'] as bool : defaults.tta,
      syncgap: number('syncgap', defaults.syncgap),
      tileSize: number('tileSize', defaults.tileSize),
      mixRatio: number('mixRatio', defaults.mixRatio),
      gpuId: number('gpuId', defaults.gpuId),
      maxInputEdge: number('maxInputEdge', defaults.maxInputEdge),
      preloadPages: number('preloadPages', defaults.preloadPages),
      legacyModelId: values['legacyModelId'] is String
          ? values['legacyModelId'] as String
          : defaults.legacyModelId,
    );
    final scale = config.supportedScales.contains(config.scale)
        ? config.scale
        : config.isLegacy
        ? config.supportedScales.first
        : 2;
    final modes = config.supportedDenoise;
    return config.copyWith(
      scale: scale,
      denoise: modes.contains(config.denoise) ? config.denoise : -1,
      syncgap: config.syncgap.clamp(0, 3).toInt(),
      tileSize:
          const {
            0,
            128,
            192,
            256,
            320,
            384,
            512,
            640,
            768,
            1024,
          }.contains(config.tileSize)
          ? config.tileSize
          : 0,
      mixRatio: config.mixRatio.clamp(0, 100).toInt(),
      gpuId: config.gpuId.clamp(0, 32).toInt(),
      maxInputEdge: config.maxInputEdge.clamp(0, 32768).toInt(),
      preloadPages: config.preloadPages.clamp(0, 64).toInt(),
    );
  }

  UpscaleConfig copyWith({
    bool? enabled,
    String? modelId,
    int? scale,
    int? denoise,
    bool? tta,
    int? syncgap,
    int? tileSize,
    int? mixRatio,
    int? gpuId,
    int? maxInputEdge,
    int? preloadPages,
    String? legacyModelId,
  }) => UpscaleConfig(
    enabled: enabled ?? this.enabled,
    modelId: modelId ?? this.modelId,
    scale: scale ?? this.scale,
    denoise: denoise ?? this.denoise,
    tta: tta ?? this.tta,
    syncgap: syncgap ?? this.syncgap,
    tileSize: tileSize ?? this.tileSize,
    mixRatio: mixRatio ?? this.mixRatio,
    gpuId: gpuId ?? this.gpuId,
    maxInputEdge: maxInputEdge ?? this.maxInputEdge,
    preloadPages: preloadPages ?? this.preloadPages,
    legacyModelId: legacyModelId ?? this.legacyModelId,
  );
}

class RealCuganUpscaler {
  RealCuganUpscaler._();

  static final instance = RealCuganUpscaler._();

  static const _settingsKey = 'upscaleConfig';
  static const _migrationKey = 'upscaleConfigVulkanMigration';
  static const _version = 1;
  static const _timeout = Duration(minutes: 5);
  static const _maxCacheBytes = 5 * 1024 * 1024 * 1024;
  static final ValueNotifier<int> configChanges = ValueNotifier(0);
  static UpscaleConfig? _globalConfig;
  static final Map<String, UpscaleConfig> _comicConfigs = {};

  String? _cachePath;
  int _generation = 0;
  int _activeProcesses = 0;
  final List<_QueuedTask> _queue = [];
  final Map<String, Future<Uint8List>> _inFlight = {};
  final Map<String, _RecentRequest> _retryRequests = {};
  final Map<String, Process> _processes = {};

  static Future<UpscaleConfig> loadConfig({
    String? comicId,
    String? sourceKey,
  }) async {
    final settings = appdata.settings;
    if (settings[_migrationKey] != _version) {
      final previousModel =
          settings['anime4KV4Model'] as String? ?? 'anime4k_x4';
      final previousEdge = (settings['anime4KV4MaxEdge'] as num?)?.toInt() ?? 0;
      final previousScale = (settings['anime4KV4Scale'] as num?)?.toInt() ?? 2;
      final fallback = UpscaleConfig.fromLegacy(
        enabled: settings['enableAnime4K'] == true,
        maxInputEdge: previousEdge,
        modelId: previousModel,
        scale: previousScale > 0 ? previousScale : 2,
      );
      settings[_settingsKey] = fallback.toJson();
      settings[_migrationKey] = _version;
      for (final entry
          in (settings['comicSpecificSettings'] as Map<String, dynamic>? ?? {})
              .entries) {
        final value = entry.value;
        if (value is Map &&
            (value.containsKey('enableAnime4K') ||
                value.containsKey('anime4KV4Model') ||
                value.containsKey('anime4KV4MaxEdge') ||
                value.containsKey('anime4KV4Scale'))) {
          final comicModel = value['anime4KV4Model'] as String? ?? previousModel;
          final comicEdge =
              (value['anime4KV4MaxEdge'] as num?)?.toInt() ?? previousEdge;
          final comicScale =
              (value['anime4KV4Scale'] as num?)?.toInt() ?? previousScale;
          value[_settingsKey] = UpscaleConfig.fromLegacy(
            enabled: value['enableAnime4K'] is bool
                ? value['enableAnime4K'] as bool
                : fallback.enabled,
            maxInputEdge: comicEdge,
            modelId: comicModel,
            scale: comicScale > 0 ? comicScale : 2,
          ).toJson();
        }
      }
      await appdata.saveData();
    }
    final global = UpscaleConfig.fromJson(settings[_settingsKey]);
    _globalConfig = global;
    if (comicId == null || sourceKey == null) return global;
    final key = '$comicId@$sourceKey';
    if (!settings.isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      _comicConfigs.remove(key);
      return global;
    }
    final override = (settings['comicSpecificSettings'] as Map?)?[key];
    if (override is! Map) {
      _comicConfigs[key] = global;
      return global;
    }
    final comicConfig = override[_settingsKey];
    if (comicConfig is Map) {
      final resolved = UpscaleConfig.fromJson(comicConfig, fallback: global);
      _comicConfigs[key] = resolved;
      return resolved;
    }
    final legacyEnabled = override['enableAnime4K'];
    final resolved = legacyEnabled is bool
        ? global.copyWith(enabled: legacyEnabled)
        : global;
    _comicConfigs[key] = resolved;
    return resolved;
  }

  static int preloadCount(String comicId, String sourceKey, int fallback) =>
      (_comicConfigs['$comicId@$sourceKey'] ?? _globalConfig)?.preloadPages ??
      fallback;

  static UpscaleConfig currentConfig(String comicId, String sourceKey) =>
      _comicConfigs['$comicId@$sourceKey'] ??
      _globalConfig ??
      const UpscaleConfig();

  Future<bool> isRuntimeAvailable() async {
    try {
      await _runtimeRoot();
      return true;
    } on Object {
      return false;
    }
  }

  static Future<void> saveConfig(
    UpscaleConfig config, {
    String? comicId,
    String? sourceKey,
  }) async {
    if (comicId != null && sourceKey != null) {
      if (!appdata.settings.isComicSpecificSettingsEnabled(
        comicId,
        sourceKey,
      )) {
        appdata.settings.setEnabledComicSpecificSettings(
          comicId,
          sourceKey,
          true,
        );
      }
      appdata.settings.setReaderSetting(
        comicId,
        sourceKey,
        _settingsKey,
        config.toJson(),
      );
    } else {
      appdata.settings[_settingsKey] = config.toJson();
      appdata.settings['enableAnime4K'] = config.enabled;
      if (config.isLegacy) {
        appdata.settings['anime4KV4Model'] = config.selectedModelId;
      }
      _globalConfig = config;
    }
    if (comicId != null && sourceKey != null) {
      _comicConfigs['$comicId@$sourceKey'] = config;
    }
    configChanges.value++;
    await instance.cancelPending('设置已更改');
    await appdata.saveData();
  }

  Future<void> _ensureInitialized() async {
    if (_cachePath != null) return;
    final directory = await getApplicationSupportDirectory();
    _cachePath = path.join(directory.path, 'upscale-vulkan-v1');
    await Directory(_cachePath!).create(recursive: true);
  }

  Future<String> _runtimeRoot() async {
    final roots = [
      path.join(path.dirname(Platform.resolvedExecutable), 'upscale'),
      path.join(Directory.current.path, 'build', 'upscale-runtime'),
    ];
    for (final root in roots) {
      final manifestFile = File(path.join(root, 'realcugan-manifest.json'));
      if (!await manifestFile.exists()) continue;
      dynamic manifest;
      try {
        manifest = jsonDecode(await manifestFile.readAsString());
      } on FormatException {
        throw const _UpscaleException('Real-CUGAN 版本清单损坏，请重新安装完整便携包。');
      }
      if (manifest is! Map ||
          manifest['version'] != _bundleVersion ||
          manifest['sha256'] != _bundleSha256)
        continue;
      final required = [
        'realcugan-ncnn-vulkan.exe',
        'vcomp140.dll',
        'LICENSE',
        for (final model in ['models-se', 'models-pro'])
          for (final weight in [
            'up2x-no-denoise.param',
            'up2x-no-denoise.bin',
            'up2x-conservative.param',
            'up2x-conservative.bin',
          ])
            path.join(model, weight),
      ];
      final complete = await Future.wait(
        required.map((relative) => File(path.join(root, relative)).exists()),
      );
      if (complete.every((present) => present)) return root;
    }
    throw _UpscaleException(
      'Real-CUGAN 引擎或模型不完整，或版本校验失败 ($_bundleVersion / '
      '${_bundleSha256.substring(0, 12)})，请重新下载完整 Windows 安装包。',
    );
  }

  Future<Uint8List> processImage({
    required Uint8List imageBytes,
    required String cacheKey,
    required String label,
    required UpscaleConfig config,
  }) async {
    if (!config.enabled || config.mixRatio == 0) return imageBytes;
    await _ensureInitialized();
    final image = img.decodeImage(imageBytes);
    if (image == null) throw const _UpscaleException('无法读取原图格式。');
    final inputDigest = sha256.convert(imageBytes).toString();
    final key = sha256
        .convert(
          utf8.encode('$_bundleVersion:${config.id}:$cacheKey:$inputDigest'),
        )
        .toString();
    final requestId = 'vulkan:${config.id}:$cacheKey';
    if (config.maxInputEdge > 0 &&
        math.max(image.width, image.height) > config.maxInputEdge) {
      UpscaleStatusTracker.instance.enqueue(
        requestId,
        label,
        config.displayModel,
      );
      UpscaleStatusTracker.instance.finish(
        requestId,
        skipped: true,
        error: '原图超过 ${config.maxInputEdge}px 长边限制。',
      );
      return imageBytes;
    }
    final output = File(path.join(_cachePath!, '$key.png'));
    if (await output.exists()) {
      try {
        final cachedBytes = await output.readAsBytes();
        final cachedImage = img.decodeImage(cachedBytes);
        if (cachedImage != null &&
            cachedImage.width == image.width * config.scale &&
            cachedImage.height == image.height * config.scale) {
          return cachedBytes;
        }
      } on Object {
        await output.deleteIgnoreError();
      }
      if (await output.exists()) {
        await output.deleteIgnoreError();
      }
    }
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final generation = _generation;
    final completion = Completer<Uint8List>();
    _inFlight[key] = completion.future;
    UpscaleStatusTracker.instance.enqueue(
      requestId,
      label,
      config.displayModel,
    );
    _rememberRetry(
      requestId,
      () => processImage(
        imageBytes: imageBytes,
        cacheKey: cacheKey,
        label: label,
        config: config,
      ),
    );
    UpscaleStatusTracker.instance.setRetryAction(
      requestId,
      () => unawaited(_retrySafely(requestId)),
    );
    _queue.add(
      _QueuedTask(requestId, completion, imageBytes, () async {
        if (generation != _generation) {
          completion.complete(imageBytes);
          return;
        }
        try {
          final result = await _runUpscale(
            image,
            config,
            requestId,
            generation,
          );
          if (generation != _generation) {
            completion.complete(imageBytes);
            return;
          }
        await _writeAtomic(output, result);
        await _pruneCache();
        _retryRequests.remove(requestId);
        completion.complete(result);
        } catch (error, stackTrace) {
          if (!completion.isCompleted) completion.complete(imageBytes);
          Log.error('RealCugan', '$error\n$stackTrace');
          UpscaleStatusTracker.instance.finish(
            requestId,
            cancelled: error is _CancelledUpscale,
            success: false,
            error: error.toString(),
          );
        } finally {
          _inFlight.remove(key);
        }
      }),
    );
    _runQueue();
    return completion.future;
  }

  void _rememberRetry(String key, Future<Uint8List> Function() retry) {
    _retryRequests.remove(key);
    _retryRequests[key] = _RecentRequest(retry);
    while (_retryRequests.length > 8) {
      _retryRequests.remove(_retryRequests.keys.first);
    }
  }

  bool hasRetry(String key) => _retryRequests.containsKey(key);

  Future<bool> retry(String key) async {
    final recent = _retryRequests[key];
    if (recent == null) throw StateError('重试数据已过期，请重新加载页面。');
    await recent.retry();
    for (final entry in UpscaleStatusTracker.instance.snapshot) {
      if (entry.key == key) {
        return entry.value.status == UpscaleJobStatus.done;
      }
    }
    return false;
  }

  Future<void> _retrySafely(String key) async {
    try {
      await retry(key);
    } catch (error, stackTrace) {
      Log.error('RealCugan', '超分任务重试失败：$error\n$stackTrace');
    }
  }

  void _runQueue() {
    while (_activeProcesses == 0 && _queue.isNotEmpty) {
      final task = _queue.removeAt(0);
      _activeProcesses++;
      unawaited(
        task.run().whenComplete(() {
          _activeProcesses--;
          _runQueue();
        }),
      );
    }
  }

  Future<Uint8List> _runUpscale(
    img.Image original,
    UpscaleConfig config,
    String requestId,
    int generation,
  ) async {
    final tracker = UpscaleStatusTracker.instance;
    final stopwatch = Stopwatch()..start();
    tracker.start(requestId);
    final input = img.Image(
      width: original.width,
      height: original.height,
      numChannels: 3,
    );
    for (var y = 0; y < original.height; y++) {
      for (var x = 0; x < original.width; x++) {
        final pixel = original.getPixel(x, y);
        input.setPixelRgb(x, y, pixel.r, pixel.g, pixel.b);
      }
    }

    final root = await _runtimeRoot();
    final executable = File(path.join(root, 'realcugan-ncnn-vulkan.exe'));
    final modelName = config.isPro ? 'models-pro' : 'models-se';
    final modelDirectory = Directory(path.join(root, modelName));
    if (!await modelDirectory.exists() || await modelDirectory.list().isEmpty) {
      throw _UpscaleException('Real-CUGAN 模型文件缺失：$modelName');
    }

    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'venera-realcugan-',
    );
    try {
      final inputFile = File(path.join(temporaryDirectory.path, 'input.png'));
      final outputFile = File(path.join(temporaryDirectory.path, 'output.png'));
      await inputFile.writeAsBytes(img.encodePng(input));
      final args = <String>[
        '-i',
        inputFile.path,
        '-o',
        outputFile.path,
        '-m',
        modelDirectory.path,
        '-s',
        '${config.scale}',
        '-n',
        '${config.denoise}',
        '-t',
        '${config.tileSize}',
        '-c',
        '${config.syncgap}',
        '-g',
        '${config.gpuId}',
        '-j',
        '1:1:1',
        '-f',
        'png',
        if (config.tta) '-x',
      ];
      var result = await _runProcess(
        executable.path,
        args,
        requestId,
        generation,
      );
      if (generation != _generation) throw const _CancelledUpscale();
      var diagnostic = '${result.stderr}\n${result.stdout}';
      final canRetryWithSmallerTile =
          config.tileSize == 0 || config.tileSize > 128;
      if (_isOutOfMemory(diagnostic) && canRetryWithSmallerTile) {
        await outputFile.deleteIgnoreError();
        final retryTile = config.tileSize == 0
            ? 384
            : math.max(128, config.tileSize ~/ 2);
        final retryArgs = [...args];
        retryArgs[retryArgs.indexOf('-t') + 1] = '$retryTile';
        result = await _runProcess(
          executable.path,
          retryArgs,
          requestId,
          generation,
        );
        if (generation != _generation) throw const _CancelledUpscale();
        diagnostic = '${result.stderr}\n${result.stdout}';
      }
      if (result.exitCode != 0 || !await outputFile.exists()) {
        throw _UpscaleException(_explainFailure(diagnostic, config.gpuId));
      }
      final outputBytes = await outputFile.readAsBytes();
      final enhanced = img.decodeImage(outputBytes);
      if (enhanced == null ||
          enhanced.width != original.width * config.scale ||
          enhanced.height != original.height * config.scale) {
        throw const _UpscaleException('Real-CUGAN 输出尺寸不正确。');
      }
      final resultImage = _composeOutput(original, enhanced, config.mixRatio);
      final encoded = Uint8List.fromList(img.encodePng(resultImage, level: 3));
      tracker.setDetails(
        requestId,
        backendName: _extractDevice(diagnostic).isEmpty
            ? 'Vulkan GPU ${config.gpuId}'
            : _extractDevice(diagnostic),
        elapsed: stopwatch.elapsed,
        outputWidth: resultImage.width,
        outputHeight: resultImage.height,
      );
      tracker.finish(requestId);
      return encoded;
    } on ProcessException catch (error) {
      throw _UpscaleException('无法启动 Real-CUGAN GPU 引擎：${error.message}');
    } finally {
      temporaryDirectory.delete(recursive: true).ignore();
    }
  }

  static img.Image _composeOutput(
    img.Image original,
    img.Image enhanced,
    int mixRatio,
  ) {
    final width = enhanced.width;
    final height = enhanced.height;
    final hasAlpha = original.hasAlpha;
    final output = img.Image(
      width: width,
      height: height,
      numChannels: hasAlpha ? 4 : 3,
    );
    final resized = mixRatio == 100
        ? null
        : img.copyResize(
            original,
            width: width,
            height: height,
            interpolation: img.Interpolation.cubic,
          );
    final resizedAlpha = hasAlpha
        ? img.copyResize(
            original,
            width: width,
            height: height,
            interpolation: img.Interpolation.cubic,
          )
        : null;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final enhancedPixel = enhanced.getPixel(x, y);
        final originalPixel = resized?.getPixel(x, y);
        double channel(num value, num? reference) => originalPixel == null
            ? value.toDouble()
            : (value * mixRatio + reference! * (100 - mixRatio)) / 100;
        output.setPixelRgba(
          x,
          y,
          channel(enhancedPixel.r, originalPixel?.r),
          channel(enhancedPixel.g, originalPixel?.g),
          channel(enhancedPixel.b, originalPixel?.b),
          resizedAlpha?.getPixel(x, y).a ?? 255,
        );
      }
    }
    return output;
  }

  Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
    String requestId,
    int generation,
  ) async {
    final child = await Process.start(
      executable,
      arguments,
      runInShell: false,
      includeParentEnvironment: true,
    );
    _processes[requestId] = child;
    final stdout = child.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = child.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      return await child.exitCode
          .then(
            (code) async =>
                ProcessResult(child.pid, code, await stdout, await stderr),
          )
          .timeout(
            _timeout,
            onTimeout: () {
              child.kill(ProcessSignal.sigkill);
              throw const _UpscaleException('Real-CUGAN GPU 超分超过 5 分钟，已停止。');
            },
          );
    } finally {
      if (generation != _generation) child.kill(ProcessSignal.sigkill);
      if (identical(_processes[requestId], child)) _processes.remove(requestId);
    }
  }

  static String _extractDevice(String output) {
    final match = RegExp(r'\[\d+ (.{1,100}?)\]').firstMatch(output);
    return match?.group(1)?.trim() ?? '';
  }

  static bool _isOutOfMemory(String diagnostic) =>
      diagnostic.toLowerCase().contains('out of memory') ||
      diagnostic.toLowerCase().contains('vk_error_out_of_device_memory') ||
      diagnostic.toLowerCase().contains('failed to allocate');

  static String _explainFailure(String diagnostic, int gpuId) {
    final lowerDiagnostic = diagnostic.toLowerCase();
    final details = diagnostic.trim().length > 4000
        ? '${diagnostic.trim().substring(0, 4000)}…'
        : diagnostic.trim();
    if (lowerDiagnostic.contains('invalid gpu device')) {
      return '找不到 GPU $gpuId，请在超分设置中选择可用的 Vulkan 显卡。';
    }
    if (lowerDiagnostic.contains('failed to create vulkan instance') ||
        lowerDiagnostic.contains('vulkan not supported') ||
        lowerDiagnostic.contains('vk_error_incompatible_driver')) {
      return 'Vulkan 显卡初始化失败，请更新显卡驱动。$details';
    }
    if (lowerDiagnostic.contains('out of memory') ||
        lowerDiagnostic.contains('vk_error_out_of_device_memory') ||
        lowerDiagnostic.contains('failed to allocate')) {
      return '显卡显存不足。请降低分块尺寸或关闭其他 GPU 程序后重试。$details';
    }
    return diagnostic.isEmpty
        ? 'Real-CUGAN 超分未输出图片，请确认完整便携包包含引擎和模型。'
        : 'GPU 超分失败：$details';
  }

  Future<void> _writeAtomic(File destination, Uint8List bytes) async {
    final temporary = File('${destination.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(destination.path);
  }

  Future<void> _pruneCache() async {
    final entries = <FileSystemEntity>[];
    var total = 0;
    await for (final entry in Directory(_cachePath!).list()) {
      if (entry is File && entry.path.endsWith('.png')) {
        entries.add(entry);
        total += await entry.length();
      }
    }
    if (total <= _maxCacheBytes) return;
    entries.sort(
      (left, right) =>
          left.statSync().modified.compareTo(right.statSync().modified),
    );
    for (final entry in entries) {
      if (total <= _maxCacheBytes) break;
      final file = entry as File;
      total -= await file.length();
      await file.deleteIgnoreError();
    }
  }

  Future<void> clearCache() async {
    await cancelPending('超分缓存已清除');
    await _ensureInitialized();
    await Directory(_cachePath!).delete(recursive: true);
    await Directory(_cachePath!).create(recursive: true);
  }

  Future<void> cancelPending(String reason) async {
    _generation++;
    _retryRequests.clear();
    for (final process in _processes.values) {
      process.kill(ProcessSignal.sigkill);
    }
    final pending = _queue.toList();
    _queue.clear();
    for (final task in pending) {
      task.cancel(reason);
    }
    _inFlight.clear();
  }
}

class _QueuedTask {
  const _QueuedTask(
    this.requestId,
    this.completion,
    this.sourceBytes,
    this.run,
  );

  final String requestId;
  final Completer<Uint8List> completion;
  final Uint8List sourceBytes;
  final Future<void> Function() run;

  void cancel(String reason) {
    UpscaleStatusTracker.instance.finish(
      requestId,
      cancelled: true,
      success: false,
      error: reason,
    );
    if (!completion.isCompleted) completion.complete(sourceBytes);
  }
}

class _RecentRequest {
  const _RecentRequest(this.retry);

  final Future<Uint8List> Function() retry;
}

class _UpscaleException implements Exception {
  const _UpscaleException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _CancelledUpscale implements Exception {
  const _CancelledUpscale();

  @override
  String toString() => '超分任务已取消。';
}
