import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:venera/utils/anime4k/realcugan_image_worker.dart';

void main() {
  test(
    'prepares RGB input off-isolate and reports source transparency',
    () async {
      final source = img.Image(width: 1, height: 1, numChannels: 4)
        ..setPixelRgba(0, 0, 10, 20, 30, 96);
      final sourceBytes = Uint8List.fromList(img.encodePng(source));

      final prepared = await prepareRealCuganImageInput(sourceBytes);
      final decodedInput = img.decodeImage(prepared.png!)!;
      final pixel = decodedInput.getPixel(0, 0);

      expect(prepared.width, 1);
      expect(prepared.height, 1);
      expect(prepared.hasTransparency, isTrue);
      expect(pixel.r, 10);
      expect(pixel.g, 20);
      expect(pixel.b, 30);
      expect(pixel.a, 255);
    },
  );

  test('validates cache dimensions using source size and scale', () async {
    final source = img.Image(width: 2, height: 3);
    final matchingOutput = img.Image(width: 4, height: 6);
    final wrongOutput = img.Image(width: 4, height: 5);

    expect(
      await validateRealCuganCache(
        sourceBytes: Uint8List.fromList(img.encodePng(source)),
        cachedBytes: Uint8List.fromList(img.encodePng(matchingOutput)),
        scale: 2,
      ),
      isTrue,
    );
    expect(
      await validateRealCuganCache(
        sourceBytes: Uint8List.fromList(img.encodePng(source)),
        cachedBytes: Uint8List.fromList(img.encodePng(wrongOutput)),
        scale: 2,
      ),
      isFalse,
    );
  });

  test('skips RGB conversion when the input edge limit is exceeded', () async {
    final source = img.Image(width: 2, height: 3);
    final prepared = await prepareRealCuganImageInput(
      Uint8List.fromList(img.encodePng(source)),
      maxInputEdge: 2,
    );

    expect(prepared.png, isNull);
    expect(prepared.width, 2);
    expect(prepared.height, 3);
  });

  test('worker errors do not block the next image job', () async {
    await expectLater(
      prepareRealCuganImageInput(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<Object>()),
    );

    final prepared = await prepareRealCuganImageInput(
      Uint8List.fromList(img.encodePng(img.Image(width: 1, height: 1))),
    );

    expect(prepared.png, isNotNull);
  });

  test('composes enhanced RGB while preserving source alpha', () async {
    final source = img.Image(width: 1, height: 1, numChannels: 4)
      ..setPixelRgba(0, 0, 0, 0, 0, 96);
    final enhanced = img.Image(width: 2, height: 2)
      ..setPixelRgba(0, 0, 100, 150, 200, 255)
      ..setPixelRgba(1, 0, 100, 150, 200, 255)
      ..setPixelRgba(0, 1, 100, 150, 200, 255)
      ..setPixelRgba(1, 1, 100, 150, 200, 255);

    final result = await composeRealCuganOutput(
      sourceBytes: Uint8List.fromList(img.encodePng(source)),
      enhancedBytes: Uint8List.fromList(img.encodePng(enhanced)),
      mixRatio: 100,
      preserveAlpha: true,
    );
    final output = img.decodeImage(result)!;
    final pixel = output.getPixel(0, 0);

    expect(output.width, 2);
    expect(output.height, 2);
    expect(pixel.r, 100);
    expect(pixel.g, 150);
    expect(pixel.b, 200);
    expect(pixel.a, greaterThan(0));
    expect(pixel.a, lessThan(255));
  });

  test('mixes original color at the configured ratio', () async {
    final source = img.Image(width: 1, height: 1)..setPixelRgb(0, 0, 0, 0, 0);
    final enhanced = img.Image(width: 2, height: 2)
      ..setPixelRgb(0, 0, 100, 150, 200)
      ..setPixelRgb(1, 0, 100, 150, 200)
      ..setPixelRgb(0, 1, 100, 150, 200)
      ..setPixelRgb(1, 1, 100, 150, 200);

    final result = await composeRealCuganOutput(
      sourceBytes: Uint8List.fromList(img.encodePng(source)),
      enhancedBytes: Uint8List.fromList(img.encodePng(enhanced)),
      mixRatio: 50,
      preserveAlpha: false,
    );
    final pixel = img.decodeImage(result)!.getPixel(0, 0);

    expect(pixel.r, 50);
    expect(pixel.g, 75);
    expect(pixel.b, 100);
  });
}
