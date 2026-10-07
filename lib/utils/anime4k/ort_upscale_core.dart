import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'upscale_models.dart';

/// 页面超过输入长边上限时的"跳过"信号（对齐 localManga 的 skipped 状态）：
/// 大图本身分辨率已足够，保持原图比"缩小再超分"更清晰。
class UpscaleSkippedException implements Exception {
  final String reason;
  UpscaleSkippedException(this.reason);

  @override
  String toString() => reason;
}

/// ONNX Runtime 分块超分核心（纯 Dart，无 Flutter 依赖，可在 Isolate/CLI 中复用）。
///
/// 处理流程逐行为对齐 localManga 的 server/upscale/engine.py：
///  1. 解码图片；长边超过 [OrtUpscaleRequest.maxInputEdge] 时抛出
///     [UpscaleSkippedException]（localManga 的 skipped 策略：超限页保持原图，
///     不做"缩小再超分"）；
///  2. RGB 归一化 float32 [0,1]（1 通道模型走 Y 亮度，色度双线性重建）；
///  3. 分块：核心 tile（默认 512）+ 每侧 16 重叠上下文，边缘块用图像边界收拢，
///     输入边长不满足 [UpscaleModelDef.inputMultiple] 时边缘复制补齐
///     （等价 np.pad mode='edge'）；
///  4. 输出 ×255 clip 写回核心区；输出恒为 输入×原生倍数；
///  5. 倍数细调：请求倍数低于原生时推理后等比缩小；
///  6. alpha 通道双线性放大；编码 PNG。
class OrtUpscaleRequest {
  final Uint8List imageBytes;
  final String modelPath;
  final UpscaleModelDef model;

  /// 输入长边上限（像素）；超过则跳过超分（保持原图）。0 = 不限制。
  final int maxInputEdge;

  /// 输出倍数（倍数细调）：低于 [UpscaleModelDef.scale] 时把推理结果等比缩小；
  /// null/大于等于原生倍数时保持原生输出。
  final int? outputScale;

  const OrtUpscaleRequest({
    required this.imageBytes,
    required this.modelPath,
    required this.model,
    this.maxInputEdge = 1600,
    this.outputScale,
  });
}

/// 创建 ONNX 会话。
///
/// 注意：必须用 [OrtSession.fromBuffer] —— Windows 上 ORTCHAR_T 为 wchar_t，
/// 而插件把 UTF-8 窄字符路径传给 CreateSession，[OrtSession.fromFile] 必然失败。
OrtSession createOrtSession(String modelPath, {int? intraOpThreads}) {
  final options = OrtSessionOptions();
  options.setIntraOpNumThreads(
      intraOpThreads ?? math.max(1, Platform.numberOfProcessors - 2));
  options.setSessionGraphOptimizationLevel(
      GraphOptimizationLevel.ortEnableAll);
  final bytes = File(modelPath).readAsBytesSync();
  return OrtSession.fromBuffer(bytes, options);
}

/// 执行分块超分，返回 PNG 字节。跳过抛 [UpscaleSkippedException]，
/// 其余失败抛异常，由调用方（worker/service）兜底。
Uint8List runOrtUpscale(
  OrtUpscaleRequest request, {
  OrtSession? session,
  void Function(double progress)? onProgress,
}) {
  final model = request.model;
  final src = img.decodeImage(request.imageBytes);
  if (src == null) {
    throw Exception('failed to decode image for upscale');
  }

  final w = src.width;
  final h = src.height;

  // 输入长边上限：超过则跳过（保持原图），对齐 localManga 的 skipped 策略
  final maxEdge = request.maxInputEdge;
  if (maxEdge > 0 && math.max(w, h) > maxEdge) {
    throw UpscaleSkippedException(
        '原图边长 ${math.max(w, h)}px 超过上限 ${maxEdge}px');
  }

  final scale = model.scale;
  final tileCore = model.tileCore > 0 ? model.tileCore : 512;
  final overlap = model.tileOverlap;

  // 源图平面数据（uint8，归一化在 tile 填充时进行）
  final srcR = Uint8List(w * h);
  final srcG = Uint8List(w * h);
  final srcB = Uint8List(w * h);
  final srcA = Uint8List(w * h);
  final hasAlpha = src.numChannels >= 4 || src.hasAlpha;
  for (final px in src) {
    final i = px.y * w + px.x;
    srcR[i] = px.r.toInt();
    srcG[i] = px.g.toInt();
    srcB[i] = px.b.toInt();
    srcA[i] = hasAlpha ? px.a.toInt() : 255;
  }

  final out = img.Image(width: w * scale, height: h * scale, numChannels: 4);
  // numChannels=4 时底层为 uint8 RGBA 连续缓冲，直接写入避免逐像素 setPixel 的开销
  final outData = (out.data as img.ImageDataUint8).data;
  final outStride = out.width * 4;

  // 会话：worker 传入常驻会话；未传入则临时创建（CLI/测试路径）
  final ownSession = session ?? createOrtSession(request.modelPath);
  try {
    final inputName = ownSession.inputNames.first;
    final totalTiles =
        ((h + tileCore - 1) ~/ tileCore) * ((w + tileCore - 1) ~/ tileCore);
    int doneTiles = 0;

    // 核心 tile 网格（对齐 localManga _run_tiles_pixels 的循环结构）
    for (int coreTop = 0; coreTop < h; coreTop += tileCore) {
      final coreBottom = math.min(h, coreTop + tileCore);
      final top = math.max(0, coreTop - overlap);
      final bottom = math.min(h, coreBottom + overlap);
      for (int coreLeft = 0; coreLeft < w; coreLeft += tileCore) {
        final coreRight = math.min(w, coreLeft + tileCore);
        final left = math.max(0, coreLeft - overlap);
        final right = math.min(w, coreRight + overlap);

        final srcW = right - left;
        final srcH = bottom - top;

        // 补齐到 inputMultiple（边缘复制，等价 np.pad mode='edge'）
        final padY = (srcH % model.inputMultiple == 0)
            ? 0
            : model.inputMultiple - srcH % model.inputMultiple;
        final padX = (srcW % model.inputMultiple == 0)
            ? 0
            : model.inputMultiple - srcW % model.inputMultiple;
        final tileH = srcH + padY;
        final tileW = srcW + padX;
        final tilePlane = tileH * tileW;

        final inData = Float32List(model.channels * tilePlane);
        for (int ty = 0; ty < tileH; ty++) {
          final sy = top + (ty < srcH ? ty : srcH - 1);
          final rowOff = sy * w;
          for (int tx = 0; tx < tileW; tx++) {
            final sx = left + (tx < srcW ? tx : srcW - 1);
            final si = rowOff + sx;
            final di = ty * tileW + tx;
            if (model.channels == 1) {
              inData[di] =
                  (0.299 * srcR[si] + 0.587 * srcG[si] + 0.114 * srcB[si]) /
                      255.0;
            } else {
              inData[di] = srcR[si] / 255.0;
              inData[tilePlane + di] = srcG[si] / 255.0;
              inData[2 * tilePlane + di] = srcB[si] / 255.0;
            }
          }
        }

        // 推理
        final input = OrtValueTensor.createTensorWithDataList(
            [inData], [1, model.channels, tileH, tileW]);
        final outputs = ownSession.run(OrtRunOptions(), {inputName: input});
        final tensor = _flattenTensor(outputs[0]?.value);
        input.release();
        outputs[0]?.release();

        // 输出空间尺寸（可变分块下为矩形，从张量维度取实际 H/W）
        final outTileH = tensor.height;
        final outTileW = tensor.width;
        final outPlane = outTileH * outTileW;

        // 裁剪核心区写回（对齐 localManga 的 crop 映射）
        final cropTop = (coreTop - top) * scale;
        final cropLeft = (coreLeft - left) * scale;
        final coreOutW = (coreRight - coreLeft) * scale;
        final coreOutH = (coreBottom - coreTop) * scale;
        final outTop = coreTop * scale;
        final outLeft = coreLeft * scale;

        for (int py = 0; py < coreOutH; py++) {
          var outRow = (outTop + py) * outStride + outLeft * 4;
          var si = (cropTop + py) * outTileW + cropLeft;
          for (int px = 0; px < coreOutW; px++) {
            double vr, vg, vb;
            if (model.channels == 1) {
              final y01 = _unit(tensor.data[si]);
              final chroma = _chromaBilinear(
                  (outLeft + px + 0.5) / scale - 0.5,
                  (outTop + py + 0.5) / scale - 0.5,
                  w,
                  h,
                  srcR,
                  srcG,
                  srcB);
              vr = y01 + 1.403 * chroma[0];
              vg = y01 - 0.714 * chroma[0] - 0.344 * chroma[1];
              vb = y01 + 1.773 * chroma[1];
            } else if (model.inputZero255) {
              vr = tensor.data[si] / 255.0;
              vg = tensor.data[outPlane + si] / 255.0;
              vb = tensor.data[2 * outPlane + si] / 255.0;
            } else {
              vr = tensor.data[si];
              vg = tensor.data[outPlane + si];
              vb = tensor.data[2 * outPlane + si];
            }
            outData[outRow] = (_unit(vr) * 255).round();
            outData[outRow + 1] = (_unit(vg) * 255).round();
            outData[outRow + 2] = (_unit(vb) * 255).round();
            outData[outRow + 3] = 255;
            outRow += 4;
            si++;
          }
        }

        doneTiles++;
        onProgress?.call(doneTiles / totalTiles);
      }
    }
  } finally {
    if (session == null) {
      ownSession.release();
    }
  }

  // alpha 通道：双线性放大（仅在源图带透明通道时重写 alpha）
  if (hasAlpha) {
    for (int dy = 0; dy < out.height; dy++) {
      final fy = (dy + 0.5) / scale - 0.5;
      for (int dx = 0; dx < out.width; dx++) {
        final fx = (dx + 0.5) / scale - 0.5;
        final a = _bilinearSample(srcA, w, h, fx, fy);
        outData[dy * outStride + dx * 4 + 3] = a;
      }
    }
  }

  // 倍数细调：请求倍数低于原生倍数时，把推理输出等比缩小
  final requestedScale = request.outputScale;
  img.Image finalImage = out;
  if (requestedScale != null &&
      requestedScale > 0 &&
      requestedScale < scale) {
    finalImage = img.copyResize(
      out,
      width: (w * requestedScale).round(),
      height: (h * requestedScale).round(),
      interpolation: img.Interpolation.cubic,
    );
  }

  return Uint8List.fromList(img.encodePng(finalImage));
}

double _unit(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 源图 [0,255] uint8 平面在浮点坐标 (fx, fy) 处的双线性采样（边界 clamp）。
int _bilinearSample(Uint8List plane, int w, int h, double fx, double fy) {
  final x0 = fx.floorToDouble().toInt();
  final y0 = fy.floorToDouble().toInt();
  final dx = fx - x0;
  final dy = fy - y0;
  final v00 = plane[_clampIdx(x0, y0, w, h)];
  final v10 = plane[_clampIdx(x0 + 1, y0, w, h)];
  final v01 = plane[_clampIdx(x0, y0 + 1, w, h)];
  final v11 = plane[_clampIdx(x0 + 1, y0 + 1, w, h)];
  return (v00 * (1 - dx) * (1 - dy) +
              v10 * dx * (1 - dy) +
              v01 * (1 - dx) * dy +
              v11 * dx * dy)
          .round() +
      0;
}

int _clampIdx(int x, int y, int w, int h) {
  final cx = x < 0 ? 0 : (x >= w ? w - 1 : x);
  final cy = y < 0 ? 0 : (y >= h ? h - 1 : y);
  return cy * w + cx;
}

/// YCbCr 色度 (Cr, Cb) 双线性插值，返回 [0,1] 空间中围绕 128 的偏差。
List<double> _chromaBilinear(double fx, double fy, int w, int h, Uint8List r,
    Uint8List g, Uint8List b) {
  final x0 = fx.floorToDouble().toInt();
  final y0 = fy.floorToDouble().toInt();
  final dx = fx - x0;
  final dy = fy - y0;
  final c00 = _chromaAt(x0, y0, w, h, r, g, b);
  final c10 = _chromaAt(x0 + 1, y0, w, h, r, g, b);
  final c01 = _chromaAt(x0, y0 + 1, w, h, r, g, b);
  final c11 = _chromaAt(x0 + 1, y0 + 1, w, h, r, g, b);
  return [
    (c00[0] * (1 - dx) * (1 - dy) +
            c10[0] * dx * (1 - dy) +
            c01[0] * (1 - dx) * dy +
            c11[0] * dx * dy) /
        255.0,
    (c00[1] * (1 - dx) * (1 - dy) +
            c10[1] * dx * (1 - dy) +
            c01[1] * (1 - dx) * dy +
            c11[1] * dx * dy) /
        255.0,
  ];
}

/// 像素 (x, y) 的 Cr/Cb（0-255 值），与 OpenCV BGR2YCrCb 一致。
List<double> _chromaAt(
    int x, int y, int w, int h, Uint8List r, Uint8List g, Uint8List b) {
  final i = _clampIdx(x, y, w, h);
  final yy = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
  return [(r[i] - yy) * 0.713 + 128.0, (b[i] - yy) * 0.564 + 128.0];
}

/// ORT 输出张量的展平结果：数据 + 实际空间尺寸（可变分块下为矩形）
class _FlatTensor {
  final Float32List data;
  final int height;
  final int width;
  const _FlatTensor(this.data, this.height, this.width);
}

/// ORT 输出张量（嵌套 List，shape [N, C, H, W]）展平，并提取 H/W。
_FlatTensor _flattenTensor(dynamic value) {
  // 沿第一元素下探获取各维长度：[N, C, H, W]
  final dims = <int>[];
  dynamic cur = value;
  while (cur is List) {
    dims.add(cur.length);
    cur = cur.isEmpty ? null : cur[0];
  }
  final w = dims.isNotEmpty ? dims.last : 0;
  final h = dims.length >= 2 ? dims[dims.length - 2] : 0;
  final out = <double>[];
  void walk(dynamic v) {
    if (v is double) {
      out.add(v);
    } else if (v is num) {
      out.add(v.toDouble());
    } else if (v is List) {
      for (final e in v) {
        walk(e);
      }
    }
  }

  walk(value);
  return _FlatTensor(Float32List.fromList(out), h, w);
}
