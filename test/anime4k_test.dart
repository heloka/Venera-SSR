import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:venera/utils/anime4k/anime4k_upscaler.dart';
import 'package:venera/utils/anime4k/ort_upscale_core.dart';
import 'package:venera/utils/anime4k/upscale_models.dart';

/// Tests for the Anime4K super-resolution component.
///
/// These tests verify the pure-Dart Anime4K implementation without relying on
/// Flutter widgets, ONNX models, or isolate infrastructure. They focus on the
/// core algorithm contract: given valid image bytes, the upscaler must produce
/// a larger, decodable PNG whose dimensions match the requested scale factor.
void main() {
  group('Anime4KUpscaler.processDirect', () {
    test('upscales a small RGB image by the given scale factor', () {
      final src = img.Image(width: 8, height: 8, numChannels: 4);
      // Draw a simple pattern: left half dark, right half bright.
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          if (x < 4) {
            src.setPixelRgba(x, y, 20, 20, 20, 255);
          } else {
            src.setPixelRgba(x, y, 230, 230, 230, 255);
          }
        }
      }

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 2.0,
        pushStrength: 0.31,
        pushGradStrength: 1.0,
      );

      final result = Anime4KUpscaler.processDirect(params);

      expect(result, isNotNull);
      expect(result!.isNotEmpty, true);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      // 8 * 2.0 = 16
      expect(decoded!.width, 16);
      expect(decoded.height, 16);
    });

    test('produces a valid PNG signature', () {
      final src = img.Image(width: 4, height: 4, numChannels: 4);
      img.fill(src, color: img.ColorRgba8(128, 128, 128, 255));

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 1.5,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNotNull);
      // PNG signature: 137 80 78 71 13 10 26 10
      expect(result![0], 0x89);
      expect(result[1], 0x50); // 'P'
      expect(result[2], 0x4E); // 'N'
      expect(result[3], 0x47); // 'G'
    });

    test('returns null for invalid image bytes', () {
      final params = Anime4KParams(
        imageBytes: Uint8List.fromList([0, 1, 2, 3, 4]),
        scaleFactor: 2.0,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNull);
    });

    test('respects scaleFactor parameter (1.0 keeps size)', () {
      final src = img.Image(width: 10, height: 6, numChannels: 4);
      img.fill(src, color: img.ColorRgba8(100, 150, 200, 255));

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 1.0,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 10);
      expect(decoded.height, 6);
    });

    test('handles 3x scale factor', () {
      final src = img.Image(width: 5, height: 5, numChannels: 4);
      for (int y = 0; y < 5; y++) {
        for (int x = 0; x < 5; x++) {
          src.setPixelRgba(x, y, x * 50, y * 50, 128, 255);
        }
      }

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 3.0,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 15);
      expect(decoded.height, 15);
    });

    test('preserves alpha channel in output', () {
      final src = img.Image(width: 6, height: 6, numChannels: 4);
      // Half transparent, half opaque.
      for (int y = 0; y < 6; y++) {
        for (int x = 0; x < 6; x++) {
          final alpha = x < 3 ? 0 : 255;
          src.setPixelRgba(x, y, 200, 100, 50, alpha);
        }
      }

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 2.0,
      );

      final result = Anime4KUpscaler.processDirect(params);
      expect(result, isNotNull);
      final decoded = img.decodeImage(result!);
      expect(decoded, isNotNull);
      // Output should be 4-channel (RGBA)
      expect(decoded!.numChannels, 4);
    });
  });

  group('Anime4KUpscaler.processInIsolate', () {
    test('falls back to direct processing when isolate fails', () async {
      final src = img.Image(width: 8, height: 8, numChannels: 4);
      img.fill(src, color: img.ColorRgba8(180, 180, 180, 255));

      final params = Anime4KParams(
        imageBytes: Uint8List.fromList(img.encodePng(src)),
        scaleFactor: 2.0,
      );

      // processInIsolate should either succeed via compute() or fall back
      // to _processImage in the current isolate. Either way, the result
      // must be non-null for valid input.
      final result = await Anime4KUpscaler.processInIsolate(params);
      expect(result, isNotNull);
      expect(result!.isNotEmpty, true);

      final decoded = img.decodeImage(result);
      expect(decoded, isNotNull);
      expect(decoded!.width, 16);
      expect(decoded.height, 16);
    });
  });

  group('UpscaleModels registry', () {
    test('ids are unique and file names are valid', () {
      final ids = UpscaleModels.all.map((m) => m.id).toSet();
      expect(ids.length, UpscaleModels.all.length);
      for (final m in UpscaleModels.all) {
        expect(m.fileName.endsWith('.onnx'), true, reason: m.id);
        expect(m.scale, greaterThanOrEqualTo(2), reason: m.id);
        expect(m.defaultUrls, isNotEmpty, reason: m.id);
        expect(m.channels, anyOf(1, 3), reason: m.id);
      }
    });

    test('tile size satisfies model alignment and padding constraints', () {
      for (final m in UpscaleModels.all) {
        expect(m.tileIn % m.inputAlign, 0,
            reason: 'tileIn must be a multiple of inputAlign for ${m.id}');
        expect(m.tilePad * 2, lessThan(m.tileIn),
            reason: 'core size must be positive for ${m.id}');
        // waifu2x cunet/swin 是 valid-conv 模型，单侧裁剪约 18px，pad 必须覆盖
        if (m.id.startsWith('waifu2x')) {
          expect(m.tilePad, greaterThanOrEqualTo(18), reason: m.id);
        }
      }
    });

    test('bundled model exists as asset declaration for default id', () {
      // 默认模型 ACNet 必须内置（保证桌面/Android 开箱即用）
      final acnet = UpscaleModels.byId('anime4k_acnet');
      expect(acnet.id, 'anime4k_acnet');
      expect(acnet.bundledAssetPath, isNotNull);
    });
  });

  group('computeTilePlan', () {
    test('tiles exactly cover the image', () {
      for (final (w, h) in [(1, 1), (100, 80), (352, 352), (353, 700), (1600, 1200)]) {
        final plan = computeTilePlan(w, h, 384, 16);
        expect(plan.core, 384 - 2 * 16);
        expect(plan.cols * plan.core, greaterThanOrEqualTo(w));
        expect(plan.rows * plan.core, greaterThanOrEqualTo(h));
        expect((plan.cols - 1) * plan.core, lessThan(w));
        expect((plan.rows - 1) * plan.core, lessThan(h));
      }
    });

    test('single tile when image fits in core size', () {
      final plan = computeTilePlan(300, 200, 384, 16);
      expect(plan.cols, 1);
      expect(plan.rows, 1);
    });

    test('rejects pad larger than half tile', () {
      expect(() => computeTilePlan(100, 100, 256, 200), throwsArgumentError);
    });
  });
}
