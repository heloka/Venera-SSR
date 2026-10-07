import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'upscale_models.dart';

/// ONNX Runtime 分块超分核心（纯 Dart，无 Flutter 依赖，可在 Isolate/CLI 中复用）。
///
/// 处理流程（与 Android 原生 ColorizeEngine.colorizeEsrgan 对齐）：
///  1. 解码图片（可选按输入长边上限缩小，控制耗时/内存）；
///  2. 3 通道模型：RGB 归一化为 float32 [0,1]；1 通道模型（ACNet）：提取 Y 亮度；
///  3. 固定边长分块（tileIn，含每侧 tilePad 的 replicate 重叠）逐块推理，
///     valid-conv 模型（waifu2x cunet/swin 输出比 2×输入小 36px）按输出实际尺寸推导裁剪；
///  4. intensity 在 [0,1] 浮点空间围绕 0.5 做对比缩放（与原生一致）；
///  5. 1 通道模型用双线性放大的 Cr/Cb 色度重建色彩；alpha 通道双线性放大；
///  6. 编码 PNG 返回。
class OrtUpscaleRequest {
  final Uint8List imageBytes;
  final String modelPath;
  final UpscaleModelDef model;

  /// 输入长边上限（像素），超过则先等比缩小；0 = 不限制。
  /// 这是桌面 CPU 推理的主要速度旋钮（参考 localManga 的 max_input_edge_px）。
  final int maxInputEdge;

  /// 对比强度（围绕 0.5 缩放），1.0 = 不变，与 Android 原生 v4 语义一致。
  final double intensity;

  const OrtUpscaleRequest({
    required this.imageBytes,
    required this.modelPath,
    required this.model,
    this.maxInputEdge = 1600,
    this.intensity = 1.0,
  });
}

/// 分块计划：core 为每块实际贡献的源边长，(cols × rows) 块覆盖整图。
class TilePlan {
  final int core;
  final int cols;
  final int rows;

  const TilePlan(this.core, this.cols, this.rows);
}

/// 计算 (w × h) 图像在 tileIn/pad 下的分块计划。
TilePlan computeTilePlan(int w, int h, int tileIn, int pad) {
  final core = tileIn - 2 * pad;
  if (core <= 0) {
    throw ArgumentError('tileIn must be larger than 2*pad');
  }
  return TilePlan(core, (w / core).ceil(), (h / core).ceil());
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

/// 执行分块超分，返回 PNG 字节。失败抛异常，由调用方（worker/service）兜底。
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

  // 输入长边上限：等比缩小源图，控制 tile 数量与耗时。
  var source = src;
  final maxEdge = request.maxInputEdge;
  if (maxEdge > 0 && math.max(src.width, src.height) > maxEdge) {
    final factor = maxEdge / math.max(src.width, src.height);
    source = img.copyResize(
      src,
      width: (src.width * factor).round(),
      height: (src.height * factor).round(),
      interpolation: img.Interpolation.linear,
    );
  }

  final w = source.width;
  final h = source.height;
  final scale = model.scale;
  final tileIn = model.tileIn;
  final pad = model.tilePad;
  final plan = computeTilePlan(w, h, tileIn, pad);

  // 源图平面数据（按 [0,255] uint8 提取，归一化在 tile 填充时进行）。
  final srcR = Uint8List(w * h);
  final srcG = Uint8List(w * h);
  final srcB = Uint8List(w * h);
  final srcA = Uint8List(w * h);
  final hasAlpha = source.numChannels >= 4 || source.hasAlpha;
  for (final px in source) {
    final i = px.y * w + px.x;
    srcR[i] = px.r.toInt();
    srcG[i] = px.g.toInt();
    srcB[i] = px.b.toInt();
    srcA[i] = hasAlpha ? px.a.toInt() : 255;
  }

  final out = img.Image(width: w * scale, height: h * scale, numChannels: 4);
  // numChannels=4 时底层为 uint8 RGBA 连续缓冲，直接写入避免逐像素 setPixel 的开销。
  final outData = (out.data as img.ImageDataUint8).data;
  final outStride = out.width * 4;

  // 会话：worker 传入常驻会话；未传入则临时创建（CLI/测试路径）。
  final ownSession = session ?? createOrtSession(request.modelPath);
  try {
    final inputName = ownSession.inputNames.first;
    final plane = tileIn * tileIn;
    final totalTiles = plan.cols * plan.rows;
    int doneTiles = 0;

    for (int cy = 0; cy < plan.rows; cy++) {
      for (int cx = 0; cx < plan.cols; cx++) {
        final x0 = cx * plan.core;
        final y0 = cy * plan.core;
        final coreW = math.min(plan.core, w - x0);
        final coreH = math.min(plan.core, h - y0);

        // ---- 填充输入 tile（replicate 边界 = BORDER_REPLICATE） ----
        final inData = Float32List(model.channels * plane);
        for (int ty = 0; ty < tileIn; ty++) {
          int sy = y0 - pad + ty;
          sy = sy < 0 ? 0 : (sy >= h ? h - 1 : sy);
          final rowOff = sy * w;
          for (int tx = 0; tx < tileIn; tx++) {
            int sx = x0 - pad + tx;
            sx = sx < 0 ? 0 : (sx >= w ? w - 1 : sx);
            final si = rowOff + sx;
            final di = ty * tileIn + tx;
            if (model.channels == 1) {
              inData[di] =
                  (0.299 * srcR[si] + 0.587 * srcG[si] + 0.114 * srcB[si]) /
                      255.0;
            } else {
              inData[di] = srcR[si] / 255.0;
              inData[plane + di] = srcG[si] / 255.0;
              inData[2 * plane + di] = srcB[si] / 255.0;
            }
          }
        }

        // ---- 推理 ----
        final input = OrtValueTensor.createTensorWithDataList(
            [inData], [1, model.channels, tileIn, tileIn]);
        final outputs = ownSession.run(OrtRunOptions(), {inputName: input});
        final outFlat = _flattenTensor(outputs[0]?.value);
        input.release();
        outputs[0]?.release();

        // ---- 由输出长度推导空间边长与裁剪（valid-conv 模型输出更小） ----
        final outPlane = outFlat.length ~/ model.channels;
        final outEdge = math.sqrt(outPlane).toInt();
        final cropStart = ((tileIn - outEdge ~/ scale) ~/ 2).clamp(0, pad);
        final base = (pad - cropStart) * scale;
        final coreOutW = coreW * scale;
        final coreOutH = coreH * scale;

        // ---- 写回核心区 ----
        final intensity = request.intensity;
        final applyIntensity = (intensity - 1.0).abs() > 1e-6;
        for (int py = 0; py < coreOutH; py++) {
          final dstY = y0 * scale + py;
          var outRow = dstY * outStride + x0 * scale * 4;
          var si = (base + py) * outEdge + base;
          for (int px = 0; px < coreOutW; px++) {
            double vr, vg, vb;
            if (model.channels == 1) {
              final y01 = _unit(outFlat[si]);
              // 色度：从源图双线性插值 Cr/Cb（dst 像素中心对应源坐标）
              final chroma = _chromaBilinear(
                  (x0 * scale + px + 0.5) / scale - 0.5,
                  (dstY + 0.5) / scale - 0.5,
                  w,
                  h,
                  srcR,
                  srcG,
                  srcB);
              vr = y01 + 1.403 * chroma[0];
              vg = y01 - 0.714 * chroma[0] - 0.344 * chroma[1];
              vb = y01 + 1.773 * chroma[1];
            } else if (model.inputZero255) {
              vr = outFlat[si] / 255.0;
              vg = outFlat[outPlane + si] / 255.0;
              vb = outFlat[2 * outPlane + si] / 255.0;
            } else {
              vr = outFlat[si];
              vg = outFlat[outPlane + si];
              vb = outFlat[2 * outPlane + si];
            }
            if (applyIntensity) {
              vr = (vr - 0.5) * intensity + 0.5;
              vg = (vg - 0.5) * intensity + 0.5;
              vb = (vb - 0.5) * intensity + 0.5;
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

  return Uint8List.fromList(img.encodePng(out));
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

/// YCbCr 色度 (Cr, Cb) 双线性插值，返回围绕 128 的偏差（已归一到 [0,1] 空间）。
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

/// 像素 (x, y) 的 Cr/Cb（围绕 128 的 0-255 值），与 OpenCV BGR2YCrCb 一致。
List<double> _chromaAt(
    int x, int y, int w, int h, Uint8List r, Uint8List g, Uint8List b) {
  final i = _clampIdx(x, y, w, h);
  final yy = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i];
  return [(r[i] - yy) * 0.713 + 128.0, (b[i] - yy) * 0.564 + 128.0];
}

/// ORT 输出张量（嵌套 List）展平为 Float32List。
Float32List _flattenTensor(dynamic value) {
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
  return Float32List.fromList(out);
}
