import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/foundation/log.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/anime4k/anime4k_service.dart';
import 'package:venera/utils/anime4k/anime4k_v4_service.dart';
import 'package:venera/utils/anime4k/anime4k_v4_model_manager.dart';
import 'package:venera/utils/anime4k/realcugan_upscaler.dart';
import 'package:venera/utils/colorization/colorization_service.dart';
import 'package:venera/utils/translations.dart';

class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
  ///
  /// [compareOriginal] 为 true 时跳过超分，但保留自定义图片处理和上色。
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.compareOriginal = false,
    this.skipUpscale = false,
  });

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  final bool compareOriginal;

  /// Keeps a gallery pre-cache from occupying the visible upscale queue.
  final bool skipUpscale;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    Uint8List? imageBytes;
    if (imageKey.startsWith('file://')) {
      // Strip the "file://" prefix to get the actual file path.
      // LocalManager stores local image keys as "file://<absolutePath>",
      // so we must remove the scheme before constructing a [File].
      var file = File(imageKey.substring(7));
      if (await file.exists()) {
        imageBytes = await file.readAsBytes();
      } else {
        throw "Error: File not found.";
      }
    } else {
      await for (var event in ImageDownloader.loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
      )) {
        checkStop();
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        );
        if (event.imageBytes != null) {
          imageBytes = event.imageBytes;
          break;
        }
      }
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    // 自此 imageBytes 非 null，用 final 捕获以便下方闭包/赋值使用
    var bytes = imageBytes;
    if (appdata.settings['enableCustomImageProcessing']) {
      var script = appdata.settings['customImageProcessing'].toString();
      if (script.contains('function processImage')) {
        var func = JsEngine().runCode('''
        (() => {
          $script
          return processImage;
        })()
      ''');
        if (func is JSInvokable) {
          var autoFreeFunction = JSAutoFreeFunction(func);
          var result = autoFreeFunction([bytes, cid, eid, page, sourceKey]);
          if (result is Uint8List) {
            bytes = result;
          } else if (result is Future) {
            var futureResult = await result;
            if (futureResult is Uint8List) {
              bytes = futureResult;
            }
          } else if (result is Map) {
            var image = result['image'];
            if (image is Uint8List) {
              bytes = image;
            } else if (image is Future) {
              JSAutoFreeFunction? onCancel;
              if (result['onCancel'] is JSInvokable) {
                onCancel = JSAutoFreeFunction(result['onCancel']);
              }
              if (onCancel == null) {
                var futureImage = await image;
                if (futureImage is Uint8List) {
                  bytes = futureImage;
                }
              } else {
                dynamic futureImage;
                image.then((value) {
                  futureImage = value;
                  futureImage ??= Uint8List(0);
                });
                while (futureImage == null) {
                  try {
                    checkStop();
                  } catch (e) {
                    onCancel([]);
                    rethrow;
                  }
                  await Future.delayed(const Duration(milliseconds: 50));
                }
                if (futureImage is Uint8List) {
                  bytes = futureImage;
                }
              }
            }
          }
        }
      }
    }
    // 超分在 ImageProvider.load 阶段处理，保持各阅读模式行为一致。
    final anime4KVersion =
        appdata.settings.getReaderSetting(
          cid,
          sourceKey ?? "",
          'anime4KVersion',
        ) ??
        'v1';
    final enableAnime4K =
        appdata.settings.getReaderSetting(
          cid,
          sourceKey ?? "",
          'enableAnime4K',
        ) ==
        true;
    if (App.isWindows) {
      try {
        final config = await RealCuganUpscaler.loadConfig(
          comicId: cid,
          sourceKey: sourceKey ?? '',
        );
        if (config.enabled &&
            !compareOriginal &&
            !skipUpscale &&
            config.isLegacy) {
          if (Anime4KV4ModelManager.selectedDef.id != config.selectedModelId) {
            await Anime4KV4Service.instance.setModel(config.selectedModelId);
          }
          final result = await Anime4KV4Service.instance.processImage(
            imageBytes: bytes,
            cacheKey: '$imageKey@$sourceKey@$cid@$eid',
            outputScale: config.scale,
            label: '${'Page'.tl} $page',
          );
          if (result != null) bytes = result;
        } else if (config.enabled && !compareOriginal && !skipUpscale) {
          bytes = await RealCuganUpscaler.instance.processImage(
            imageBytes: bytes,
            cacheKey: '$imageKey@$sourceKey@$cid@$eid',
            label: '${'Page'.tl} $page',
            config: config,
          );
        }
      } catch (e, s) {
        Log.error('ReaderImage', 'Real-CUGAN GPU 超分失败：$e', s);
      }
    }
    if (enableAnime4K && !App.isWindows && !compareOriginal) {
      if (anime4KVersion == 'v4' && Anime4KV4Service.instance.isAvailable) {
        try {
          final result = await Anime4KV4Service.instance.processImage(
            imageBytes: bytes,
            cacheKey: key,
            outputScale:
                ((appdata.settings.getReaderSetting(
                          cid,
                          sourceKey ?? "",
                          'anime4KV4Scale',
                        )
                        as num?)
                    ?.toInt()) ??
                0,
            label: '第 $page 页',
          );
          if (result != null) {
            bytes = result;
          }
        } catch (e, s) {
          Log.error('ReaderImage', 'Anime4K v4 processing error: $e', s);
        }
      } else {
        try {
          final result = await Anime4KService.instance.processImage(
            imageBytes: bytes,
            cacheKey: key,
            label: '第 $page 页',
            scaleFactor:
                (appdata.settings.getReaderSetting(
                          cid,
                          sourceKey ?? "",
                          'anime4KScaleFactor',
                        )
                        as num?)
                    ?.toDouble() ??
                2.0,
            pushStrength:
                (appdata.settings.getReaderSetting(
                          cid,
                          sourceKey ?? "",
                          'anime4KPushStrength',
                        )
                        as num?)
                    ?.toDouble() ??
                0.31,
            pushGradStrength:
                (appdata.settings.getReaderSetting(
                          cid,
                          sourceKey ?? "",
                          'anime4KPushGradStrength',
                        )
                        as num?)
                    ?.toDouble() ??
                1.0,
          );
          if (result != null) {
            bytes = result;
          }
        } catch (e, s) {
          Log.error('ReaderImage', 'Anime4K processing error: $e', s);
        }
      }
    }

    // ===== AI 上色处理 =====
    final enableColorization =
        appdata.settings.getReaderSetting(
          cid,
          sourceKey ?? "",
          'enableColorization',
        ) ==
        true;
    if (enableColorization) {
      try {
        if (!ColorizationService.instance.isModelAvailable) {
          await ColorizationService.instance.checkModelAvailable();
        }
        if (ColorizationService.instance.isModelAvailable) {
          final result = await ColorizationService.instance.processImage(
            imageBytes: bytes,
            cacheKey: key,
            intensity:
                (appdata.settings.getReaderSetting(
                          cid,
                          sourceKey ?? "",
                          'colorizationIntensity',
                        )
                        as num?)
                    ?.toDouble() ??
                1.0,
          );
          if (result != null) {
            bytes = result;
          }
        }
      } catch (e, s) {
        Log.error('ReaderImage', 'Colorization processing error: $e', s);
      }
    }

    checkStop();
    return bytes;
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key {
    final base = "$imageKey@$sourceKey@$cid@$eid";
    final rawVariant = compareOriginal ? '|raw' : '';
    if (!App.isWindows) return '$base$rawVariant';
    final config = RealCuganUpscaler.currentConfig(cid, sourceKey ?? '');
    final preCacheVariant = skipUpscale ? '|upscale-prefetch' : '';
    return '$base$rawVariant|upscale:${config.id}:${config.enabled}$preCacheVariant';
  }

  @override
  bool get enableResize => false;
}
