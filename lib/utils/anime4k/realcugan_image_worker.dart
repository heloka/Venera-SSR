import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

typedef RealCuganImageInput = ({
  Uint8List? png,
  int width,
  int height,
  bool hasTransparency,
});

Future<void> _imageWorkerTail = Future<void>.value();

Future<T> _serializeImageWork<T>(Future<T> Function() work) {
  final result = Completer<T>();
  final previous = _imageWorkerTail;
  _imageWorkerTail = previous.then((_) async {
    try {
      result.complete(await work());
    } catch (error, stackTrace) {
      result.completeError(error, stackTrace);
    }
  });
  return result.future;
}

Future<RealCuganImageInput> prepareRealCuganImageInput(
  Uint8List sourceBytes, {
  int maxInputEdge = 0,
}) => _serializeImageWork(
  () => Isolate.run(() {
    final original = img.decodeImage(sourceBytes);
    if (original == null) {
      throw const FormatException('Unable to decode source image.');
    }
    if (maxInputEdge > 0 &&
        math.max(original.width, original.height) > maxInputEdge) {
      return (
        png: null,
        width: original.width,
        height: original.height,
        hasTransparency: false,
      );
    }

    final input = img.Image(
      width: original.width,
      height: original.height,
      numChannels: 3,
    );
    var hasTransparency = false;
    for (var y = 0; y < original.height; y++) {
      for (var x = 0; x < original.width; x++) {
        final pixel = original.getPixel(x, y);
        if (pixel.a < 255) hasTransparency = true;
        input.setPixelRgb(x, y, pixel.r, pixel.g, pixel.b);
      }
    }

    return (
      png: Uint8List.fromList(img.encodePng(input)),
      width: original.width,
      height: original.height,
      hasTransparency: hasTransparency,
    );
  }, debugName: 'real-cugan-input'),
);

Future<bool> validateRealCuganCache({
  required Uint8List sourceBytes,
  required Uint8List cachedBytes,
  required int scale,
}) => _serializeImageWork(
  () => Isolate.run(() {
    final source = img.decodeImage(sourceBytes);
    final cached = img.decodeImage(cachedBytes);
    return source != null &&
        cached != null &&
        cached.width == source.width * scale &&
        cached.height == source.height * scale;
  }, debugName: 'real-cugan-cache-check'),
);

Future<Uint8List> composeRealCuganOutput({
  required Uint8List sourceBytes,
  required Uint8List enhancedBytes,
  required int mixRatio,
  required bool preserveAlpha,
}) => _serializeImageWork(
  () => Isolate.run(() {
    final original = img.decodeImage(sourceBytes);
    final enhanced = img.decodeImage(enhancedBytes);
    if (original == null || enhanced == null) {
      throw const FormatException('Unable to decode upscale images.');
    }

    final width = enhanced.width;
    final height = enhanced.height;
    final output = img.Image(
      width: width,
      height: height,
      numChannels: preserveAlpha ? 4 : 3,
    );
    final resized = mixRatio == 100
        ? null
        : img.copyResize(
            original,
            width: width,
            height: height,
            interpolation: img.Interpolation.cubic,
          );
    final resizedAlpha = preserveAlpha
        ? img.copyResize(
            original,
            width: width,
            height: height,
            interpolation: img.Interpolation.cubic,
          )
        : null;
    final originalWeight = 100 - mixRatio;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final enhancedPixel = enhanced.getPixel(x, y);
        final originalPixel = resized?.getPixel(x, y);
        final alpha = resizedAlpha?.getPixel(x, y).a ?? 255;
        if (originalPixel == null) {
          output.setPixelRgba(
            x,
            y,
            enhancedPixel.r,
            enhancedPixel.g,
            enhancedPixel.b,
            alpha,
          );
        } else {
          output.setPixelRgba(
            x,
            y,
            (enhancedPixel.r * mixRatio + originalPixel.r * originalWeight) /
                100,
            (enhancedPixel.g * mixRatio + originalPixel.g * originalWeight) /
                100,
            (enhancedPixel.b * mixRatio + originalPixel.b * originalWeight) /
                100,
            alpha,
          );
        }
      }
    }
    return Uint8List.fromList(img.encodePng(output, level: 3));
  }, debugName: 'real-cugan-output'),
);
