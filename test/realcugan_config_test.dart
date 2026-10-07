import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/anime4k/realcugan_upscaler.dart';

void main() {
  group('UpscaleConfig', () {
    test('defaults to conservative SE 2x with GPU 0', () {
      const config = UpscaleConfig();

      expect(config.enabled, isTrue);
      expect(config.modelId, 'real-cugan-se');
      expect(config.scale, 2);
      expect(config.denoise, -1);
      expect(config.tta, isFalse);
      expect(config.syncgap, 3);
      expect(config.tileSize, 0);
      expect(config.mixRatio, 100);
      expect(config.gpuId, 0);
      expect(config.maxInputEdge, 0);
      expect(config.preloadPages, 8);
    });

    test('exposes denoise modes supported by the selected model and scale', () {
      expect(const UpscaleConfig().supportedDenoise, [-1, 0, 1, 2, 3]);
      expect(const UpscaleConfig(scale: 3).supportedDenoise, [-1, 0, 3]);
      expect(const UpscaleConfig(modelId: 'real-cugan-pro').supportedScales, [
        2,
        3,
      ]);
      expect(const UpscaleConfig(modelId: 'real-cugan-pro').supportedDenoise, [
        -1,
        0,
        3,
      ]);
    });

    test('normalizes unsupported and out-of-range persisted values', () {
      final config = UpscaleConfig.fromJson({
        'modelId': 'real-cugan-pro',
        'scale': 4,
        'denoise': 2,
        'syncgap': -1,
        'tileSize': 129,
        'mixRatio': 101,
        'gpuId': -1,
        'maxInputEdge': 99999,
        'preloadPages': 65,
      });

      expect(config.scale, 2);
      expect(config.denoise, -1);
      expect(config.syncgap, 0);
      expect(config.tileSize, 0);
      expect(config.mixRatio, 100);
      expect(config.gpuId, 0);
      expect(config.maxInputEdge, 32768);
      expect(config.preloadPages, 64);
    });

    test(
      'isolates cache identities by output parameters, not toggle state',
      () {
        const base = UpscaleConfig();
        expect(base.id, base.copyWith(enabled: false, preloadPages: 32).id);
        expect(base.id, isNot(base.copyWith(scale: 3).id));
        expect(base.id, isNot(base.copyWith(mixRatio: 50).id));
        expect(base.id, isNot(base.copyWith(modelId: 'real-cugan-pro').id));
      },
    );

    test('accepts only registered legacy models', () {
      expect(
        UpscaleConfig.fromJson({'modelId': 'legacy:anime4k_x4'}).isLegacy,
        isTrue,
      );
      expect(
        UpscaleConfig.fromJson({'modelId': 'legacy:unknown'}).modelId,
        'real-cugan-se',
      );
    });

    test('migrates the previous toggle, model, and no-limit edge setting', () {
      final migrated = UpscaleConfig.fromLegacy(
        enabled: true,
        modelId: 'mangajanai_1600p_2x',
        maxInputEdge: 0,
        scale: 3,
      );

      expect(migrated.enabled, isTrue);
      expect(migrated.modelId, 'real-cugan-se');
      expect(migrated.legacyModelId, 'mangajanai_1600p_2x');
      expect(migrated.maxInputEdge, 0);
      expect(migrated.scale, 3);
    });
  });
}
