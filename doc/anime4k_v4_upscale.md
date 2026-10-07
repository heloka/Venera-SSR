# v4 AI 超分（跨平台 ONNX 引擎）

## 背景

v4 AI 超分原先仅 Android 可用（原生 ONNX Runtime + NNAPI），Windows/Linux/macOS 上
选择 v4 时静默回退 v1 纯 CPU 算法，表现为"超分失败"或长时间无响应。

现在 v4 在桌面端（Windows / Linux / macOS）通过 `onnxruntime` Dart FFI 插件运行，
无需任何原生构建改动（插件自带各平台动态库，Flutter 打包时自动部署到 exe 旁）。

## 架构

```
reader_image.dart
  └─ Anime4KV4Service.processImage()          // 缓存 + 队列 + 平台路由
       ├─ Android: MethodChannel → ColorizeEngine（NNAPI GPU，失败回退 CPU，原生不变）
       └─ 桌面:   OrtUpscaleWorker（常驻 isolate，会话只加载一次）
              └─ ort_upscale_core.runOrtUpscale()  // 纯 Dart 分块推理
                   ├─ upscale_models.dart       // 模型注册表（纯 Dart）
                   └─ onnxruntime (FFI)          // ORT 1.17 CPU EP
```

- **模型注册表** `lib/utils/anime4k/upscale_models.dart`：Anime4K ACNet（内置）/
  Real-ESRGAN animevideov3（内置下载源）/ MangaJaNai（黑白漫画专用）/ Waifu2x
  CUNet、SwinIR / Real-ESRGAN general-x4v3，参考 mihon_img_upscale 与 localManga
  的常用模型集。新增模型只需追加一项（含归一化/分块/对齐参数与下载镜像）。
- **分块推理** `ort_upscale_core.dart`：固定 tileIn 边长 + tilePad 重叠
  （BORDER_REPLICATE 语义），valid-conv 模型（waifu2x cunet/swin 输出比 2×输入小
  36px）按输出实际尺寸推导裁剪偏移；1 通道模型（ACNet）走 Y 亮度 + Cr/Cb 双线性
  色度重建，与 Android 原生管线一致；intensity 与原生同为围绕 0.5 的对比缩放。
- **常驻 worker** `ort_upscale_worker.dart`：ONNX 会话不可跨 isolate，故固定在
  长驻 isolate 中，大模型只加载一次；请求按序执行，带进度回传与超时保护；
  worker 崩溃时服务自动重建重试一次。
- **输入长边上限**（`anime4KV4MaxEdge`，默认 1600，0=不限制）：超限时先等比缩小
  再分块，是桌面 CPU 推理的主要速度/内存旋钮（参考 localManga 的 max_input_edge_px）。

## 推理行为（对齐 localManga engine.py）

- **分块**：核心 tile 512 + 每侧 16 重叠上下文（边缘块用图像边界收拢），
  输入边长不满足模型 `inputMultiple`（MangaJaNai=2，pixel-unshuffle 需偶数）时边缘复制补齐；
  输出恒为 输入×原生倍数，按核心区裁剪写回。
- **输入策略（重要）**：长边超过 `anime4KV4MaxEdge`（默认 1600）的页面**跳过超分、
  保持原图**（localManga 的 skipped 策略），不做"缩小再超分"。
- **默认配置对齐 localManga DEFAULT_CONFIG**：默认模型 realesr-animevideov3、输出 2×
  （4× 推理后缩小）、长边上限 1600。
- **模型集**：仅收录"输出 = 输入×倍数"的 ONNX 模型（ESRGAN/SRVGGNetCompact 家族）；
  waifu2x cunet/swin 为 valid-conv 模型（输出带裁剪），localManga 经 ncnn 处理，
  Dart 引擎不收录，避免裁剪偏差。

## 已验证模型（sha256 已知处下载后校验）

| 模型 | 倍数 | 体积 | 速度（i5-14600KF, CPU） | 说明 |
|---|---|---|---|---|
| anime4k_acnet（内置） | 2× | 21KB | ~0.9s / 700×451 页 | 开箱即用 |
| realesr_animevideov3 | 4×（可输出 3×/2×） | 2.4MB | ~1s / 300×217 页 | **默认**，动漫视频 |
| mangajanai_1600p_2x | 2× | 64MB | ~5.5s / 700×451 页 | 黑白漫画/文字/网点专用 |
| realesr_general_x4v3 | 4×（可输出 3×/2×） | 4.6MB | ~13s / 560×420 页 | 照片/彩页通用 |

所有模型输入/输出均为 float32 NCHW、动态尺寸、0-1 归一化（/255）。

## 关键坑（新增引擎时注意）

1. **Windows 上 `OrtSession.fromFile` 必然失败**：ORT 的 Windows 构建中
   `ORTCHAR_T = wchar_t`，而插件传 UTF-8 窄字符路径。必须用
   `OrtSession.fromBuffer`（读入内存创建会话）。
2. `OrtValueTensor.createTensorWithDataList` 依赖 `List.element()` 判定元素类型：
   传 `[float32List]`（嵌套一层）才是 float32；直接传 `Float32List` 会被当成 double。
3. waifu2x cunet/swin 是 valid-conv（无 padding）模型：tileIn=256 时输出 440
   （每边裁 18px），分块 pad 必须 ≥18 且写回偏移为 `(pad - crop)*scale`。
4. 插件 Windows/Linux/macOS 动态库由 CMake `bundled_libraries` 自动部署，
   无需改 `windows/runner`。

## CI

`.github/workflows/*` 的 Flutter 版本已与 pubspec 固定版本（3.38.5）对齐；
原先 CI 用 3.41.2 会在 `flutter pub get` 阶段因版本不满足直接失败。
