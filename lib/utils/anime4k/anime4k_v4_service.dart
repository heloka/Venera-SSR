import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';

import 'anime4k_v4_model_manager.dart';
import 'ort_upscale_core.dart';
import 'ort_upscale_worker.dart';
import 'upscale_status_tracker.dart';

/// Anime4K v4 超分服务（带模型版本）
///
/// 基于 AI 超分 ONNX 模型（默认官方 ACNet 2×，可选 Real-ESRGAN / MangaJaNai /
/// Waifu2x 家族，见 [UpscaleModels.all]），倍数由模型实际维度决定。
///
/// 按平台路由推理后端：
///  - Android：经 [com.github.kiastr.venera_ssr/colorize] MethodChannel 调用原生
///    （Kotlin + ONNX Runtime + NNAPI GPU），失败自动回退 CPU；
///  - Windows / Linux / macOS：onnxruntime Dart FFI（插件自带各平台动态库），
///    在常驻 isolate 中分块推理（[OrtUpscaleWorker]），模型只加载一次。
///
/// 与 v1（纯 Dart CPU 算法）并存：reader 侧按 `anime4KVersion` 选择引擎。
class Anime4KV4Service {
  Anime4KV4Service._internal();

  static final Anime4KV4Service _instance = Anime4KV4Service._internal();

  factory Anime4KV4Service() => _instance;

  static Anime4KV4Service get instance => _instance;

  /// 与原生端通信的 MethodChannel（复用上色通道）
  static const MethodChannel _channel =
      MethodChannel('com.github.kiastr.venera_ssr/colorize');

  /// 桌面端 ONNX Runtime（Dart FFI）是否可用（iOS 依赖静态链接，暂不支持）
  static bool get _ortSupported =>
      App.isWindows || App.isLinux || App.isMacOS;

  String? _cacheDir;
  String? _modelPath;
  OrtUpscaleWorker? _worker;

  final Set<String> _processingKeys = {};
  static const int _maxConcurrentTasks = 2;
  int _runningTasks = 0;
  final List<Function> _taskQueue = [];

  /// 初始化缓存目录并探测模型（不自动下载）
  Future<void> init() async {
    try {
      final dir = await getTemporaryDirectory();
      _cacheDir = path.join(dir.path, 'anime4k_v4_cache');
      final cacheDirectory = Directory(_cacheDir!);
      if (!await cacheDirectory.exists()) {
        await cacheDirectory.create(recursive: true);
      }
      // 同步“当前选中模型”（默认 ACNet 2x），再抽取内置模型/确认可用
      await Anime4KV4ModelManager.setSelectedModelId(
        (appdata.settings['anime4KV4Model'] as String?) ?? 'anime4k_x4',
      );
      await Anime4KV4ModelManager.extractBundledModelIfNeeded();
      _modelPath = await Anime4KV4ModelManager.ensureModelAvailable();
    } catch (e) {
      Log.error('Anime4KV4', 'init error: $e');
    }
  }

  /// 切换 v4 超分模型（不同倍数输出尺寸不同）。重置后端会话（Android 原生 /
  /// 桌面 worker isolate）、清空超分缓存（缓存不可跨模型复用）。
  Future<void> setModel(String id) async {
    if (!Anime4KV4ModelManager.isValidModelId(id)) return;
    await Anime4KV4ModelManager.setSelectedModelId(id);
    appdata.settings['anime4KV4Model'] = id;
    appdata.saveData();
    await _resetBackendSession();
    await Anime4KV4ModelManager.extractBundledModelIfNeeded();
    _modelPath = await Anime4KV4ModelManager.ensureModelAvailable();
    await clearCache();
  }

  /// 释放后端已加载的模型会话（模型变更/导入/删除后必须调用）
  Future<void> _resetBackendSession() async {
    if (_worker != null) {
      try {
        await _worker!.reset();
      } catch (e) {
        Log.error('Anime4KV4', 'worker reset failed: $e');
      }
    }
    try {
      await _channel.invokeMethod<void>('resetSession');
    } catch (e) {
      // 非 Android 平台没有该通道，忽略
    }
  }

  /// 模型是否可用（已下载到本地且当前平台有可用推理后端）
  bool get isAvailable =>
      (App.isAndroid || _ortSupported) && _modelPath != null;

  Future<bool> checkModelAvailable() async {
    if (_modelPath != null) {
      if (await File(_modelPath!).exists()) return true;
      _modelPath = null;
    }
    _modelPath = await Anime4KV4ModelManager.ensureModelAvailable();
    return _modelPath != null;
  }

  String? _getCachePath(String key) {
    if (_cacheDir == null) return null;
    return path.join(_cacheDir!, '${key.hashCode.abs()}.png');
  }

  Future<Uint8List?> _getFromCache(String key) async {
    final cachePath = _getCachePath(key);
    if (cachePath == null) return null;
    final file = File(cachePath);
    if (await file.exists()) {
      try {
        return await file.readAsBytes();
      } catch (e) {
        return null;
      }
    }
    return null;
  }

  Future<void> _saveToCache(String key, Uint8List data) async {
    final cachePath = _getCachePath(key);
    if (cachePath == null) return;
    try {
      final file = File(cachePath);
      await file.writeAsBytes(data);
    } catch (e) {
      Log.error('Anime4KV4', 'cache save error: $e');
    }
  }

  /// 调用原生端完成超分推理（type='esrgan'）。
  /// 优先 NNAPI（GPU），失败自动回退纯 CPU；任何失败返回 null（不抛异常）。
  Future<Uint8List?> _upscaleOnNative(
    Uint8List imageBytes,
    String modelPath,
    bool useNnapi,
  ) async {
    try {
      final result = await _channel.invokeMethod<Uint8List>('colorize', {
        'imageBytes': imageBytes,
        'modelPath': modelPath,
        'type': 'esrgan',
        'useNnapi': useNnapi,
        'intensity': 1.0,
      });
      return result;
    } catch (e, s) {
      Log.error('Anime4KV4', 'native upscale failed (useNnapi=$useNnapi): $e\n$s');
      return null;
    }
  }

  /// 丢弃后端已缓存的 ONNX 会话（模型变更/导入/删除后必须调用）。
  /// Android 为原生会话；桌面为 worker isolate 中的会话。
  Future<void> resetNativeSession() => _resetBackendSession();

  /// 处理图片字节数据，返回超分后的 PNG 字节数据（倍数由模型与 [outputScale] 决定）。
  ///
  /// 模型缺失或平台无推理后端时返回 null（上层据此回退 v1 或保持原图）。
  /// [outputScale] 为倍数细调：低于模型原生倍数时推理后缩小；null = 原生。
  /// [label] 为任务状态展示标签（如 "第 3 页"）。
  ///
  /// 输入策略对齐 localManga：长边超过 `anime4KV4MaxEdge` 的页面跳过超分
  /// （返回 null，reader 保持原图），不做"缩小再超分"。
  Future<Uint8List?> processImage({
    required Uint8List imageBytes,
    required String cacheKey,
    int? outputScale,
    String? label,
  }) async {
    if (!(App.isAndroid || _ortSupported)) {
      return null;
    }
    if (_modelPath == null) {
      if (!await checkModelAvailable()) {
        Log.warning('Anime4KV4', 'Model not available, skipping for $cacheKey');
        return null;
      }
    }
    final modelPath = _modelPath;
    if (modelPath == null) return null;

    final def = Anime4KV4ModelManager.selectedDef;
    final effScale = resolveOutputScale(def, outputScale ?? 0);
    final maxEdge =
        (appdata.settings['anime4KV4MaxEdge'] as num?)?.toInt() ?? 1600;

    // 缓存键含模型 id + 有效输出倍数 + 长边上限，避免串图
    final fullKey =
        'v4_${def.id}_s${effScale}_e${maxEdge}_$cacheKey';

    final tracker = UpscaleStatusTracker.instance;
    final showLabel = label ?? cacheKey;

    final cached = await _getFromCache(fullKey);
    if (cached != null) {
      Log.info('Anime4KV4', 'cache hit for $cacheKey');
      return cached;
    }

    if (_processingKeys.contains(fullKey)) {
      Log.info('Anime4KV4', 'already processing $cacheKey');
      return null;
    }

    _processingKeys.add(fullKey);
    tracker.enqueue(fullKey, showLabel, def.id);

    return _enqueueTask(() async {
      try {
        Log.info('Anime4KV4',
            'processing image $cacheKey (${def.id}, scale=$effScale, maxEdge=$maxEdge)');
        tracker.start(fullKey);

        Uint8List? result;
        if (App.isAndroid) {
          // Android 原生无长边跳过策略，先在 Dart 侧做同样的尺寸检查
          _checkSkip(imageBytes, maxEdge);
          result = await _upscaleOnNative(imageBytes, modelPath, true);
          // NNAPI 失败（不支持/崩溃）时回退纯 CPU 重试一次
          result ??= await _upscaleOnNative(imageBytes, modelPath, false);
          // Android 原生输出固定为原生倍数，倍数细调在此后处理
          if (result != null && effScale < def.scale) {
            result = await resizePngIsolate(result, effScale / def.scale);
          }
        } else {
          result = await _upscaleOnDesktop(
              imageBytes, modelPath, maxEdge, def, effScale, fullKey);
        }

        if (result != null) {
          await _saveToCache(fullKey, result);
          Log.info('Anime4KV4', 'processing complete for $cacheKey');
        }
        tracker.finish(fullKey, success: result != null,
            error: result == null ? '处理失败' : null);
        return result;
      } catch (e, s) {
        Log.error('Anime4KV4', 'processing error: $e\n$s');
        tracker.finish(fullKey, success: false, error: '$e');
        return null;
      } finally {
        _processingKeys.remove(fullKey);
      }
    });
  }

  /// 桌面端：常驻 worker isolate 中分块推理。
  /// worker 崩溃/超时则重建一次重试，仍失败返回 null（reader 回退 v1/原图）。
  Future<Uint8List?> _upscaleOnDesktop(Uint8List imageBytes,
      String modelPath, int maxEdge, UpscaleModelDef def,
      int effScale, String trackerKey) async {
    for (int attempt = 0; attempt < 2; attempt++) {
      OrtUpscaleWorker? worker = _worker;
      try {
        worker ??= await OrtUpscaleWorker.spawn();
        _worker = worker;
        await worker.ensureLoaded(def, modelPath);
        final sw = Stopwatch()..start();
        final result = await worker.run(
          OrtUpscaleRequest(
            imageBytes: imageBytes,
            modelPath: modelPath,
            model: def,
            maxInputEdge: maxEdge,
            outputScale: effScale,
          ),
          onProgress: (p) {
            UpscaleStatusTracker.instance.progress(trackerKey, p);
            if (p == 0 || (p * 100).round() % 25 == 0) {
              Log.info('Anime4KV4',
                  'progress ${(p * 100).toStringAsFixed(0)}%');
            }
          },
        );
        Log.info('Anime4KV4',
            'desktop upscale done in ${sw.elapsedMilliseconds}ms');
        return result;
      } catch (e, s) {
        Log.error('Anime4KV4',
            'desktop upscale failed (attempt ${attempt + 1}): $e\n$s');
        // worker 可能已崩溃/失联：销毁并重建后重试
        _worker?.dispose();
        _worker = null;
      }
    }
    return null;
  }

  Future<T?> _enqueueTask<T>(Future<T?> Function() task) async {
    final completer = Completer<T?>();
    _taskQueue.add(() async {
      _runningTasks++;
      try {
        final result = await task();
        completer.complete(result);
      } catch (e) {
        completer.completeError(e);
      } finally {
        _runningTasks--;
        _nextTask();
      }
    });
    _nextTask();
    return completer.future;
  }

  void _nextTask() {
    if (_runningTasks < _maxConcurrentTasks && _taskQueue.isNotEmpty) {
      final task = _taskQueue.removeAt(0);
      task();
    }
  }

  Future<void> clearCache() async {
    if (_cacheDir == null) return;
    try {
      final dir = Directory(_cacheDir!);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
      Log.info('Anime4KV4', 'cache cleared');
    } catch (e) {
      Log.error('Anime4KV4', 'cache clear error: $e');
    }
  }

  Future<int> getCacheSize() async {
    if (_cacheDir == null) return 0;
    try {
      final dir = Directory(_cacheDir!);
      if (!await dir.exists()) return 0;
      int totalSize = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }
}

/// 轻量检查图片长边是否超过上限（对齐 localManga 的 skipped 策略）。
/// Android 原生路径没有内置该策略，在提交任务前检查。
void _checkSkip(Uint8List imageBytes, int maxEdge) {
  if (maxEdge <= 0) return;
  final src = img.decodeImage(imageBytes);
  if (src == null) return;
  if (math.max(src.width, src.height) > maxEdge) {
    throw UpscaleSkippedException(
        '原图边长 ${math.max(src.width, src.height)}px 超过上限 ${maxEdge}px');
  }
}

/// 在 isolate 中把 PNG 字节按 [factor] 等比缩小（Android 原生输出后的倍数细调）。
Future<Uint8List?> resizePngIsolate(Uint8List pngBytes, double factor) async {
  return Isolate.run(() => _resizePngSync(pngBytes, factor));
}

Uint8List? _resizePngSync(Uint8List pngBytes, double factor) {
  try {
    final src = img.decodeImage(pngBytes);
    if (src == null) return null;
    final resized = img.copyResize(
      src,
      width: (src.width * factor).round(),
      height: (src.height * factor).round(),
      interpolation: img.Interpolation.cubic,
    );
    return Uint8List.fromList(img.encodePng(resized));
  } catch (e) {
    Log.error('Anime4KV4', 'resize failed: $e');
    return null;
  }
}
