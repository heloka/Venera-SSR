/// ONNX 超分模型注册表（纯 Dart，无 Flutter 依赖）。
///
/// Android 原生（ONNX Runtime + NNAPI）与桌面端（onnxruntime Dart FFI）共用同一注册表。
/// 模型集参考 mihon_img_upscale（Real-ESRGAN / Waifu2x 家族）与 localManga
/// （MangaJaNai 黑白漫画专用），全部为动态尺寸 ONNX，分块推理。
///
/// 新增模型只需在 [UpscaleModels.all] 追加一项，并保证：
///  - ONNX 输入/输出为动态尺寸（NCHW），float32；
///  - 归一化约定记录在 [inputZero255]（当前所有模型均为 0-1，即 /255）；
///  - [tileIn] 是 [inputAlign] 的倍数，且 [tilePad] ≥ 模型单侧有效裁剪（valid-conv 模型如
///    waifu2x cunet/swin 单侧裁 18px）。
class UpscaleModelDef {
  final String id;

  /// 模型落盘文件名（getApplicationSupportDirectory 目录下）
  final String fileName;

  final String displayName;

  /// 一句话说明（UI 展示：适用场景/速度特征）
  final String description;

  /// 原生放大倍数（仅 UI 提示；真实倍数由模型维度决定）
  final int scale;

  final int sizeHintMB;

  /// 模型输入通道数：1 = Y 亮度（官方 ACNet），3 = RGB
  final int channels;

  /// 模型是否使用 0-255 浮点输入/输出；false = 0-1（/255 归一化，当前全部模型）
  final bool inputZero255;

  /// 分块输入边长（像素）。模型可能对输入有整除约束（见 [inputAlign]）。
  final int tileIn;

  /// 分块每侧重叠像素：覆盖感受野并消除接缝；valid-conv 模型还需 ≥ 单侧裁剪。
  final int tilePad;

  /// [tileIn] 必须是它的倍数（cunet=4 / swin=8；ESRGAN 类无约束取 1）
  final int inputAlign;

  /// 打包进安装包的内置模型（开箱即用；桌面与 Android 均从 Flutter assets 抽取）
  final String? bundledAssetPath;

  /// 下载地址（依次尝试；优先镜像以便国内直连）
  final List<String> defaultUrls;

  /// 已知模型文件的 sha256（下载后校验；未知则为 null）
  final String? sha256;

  const UpscaleModelDef({
    required this.id,
    required this.fileName,
    required this.displayName,
    required this.description,
    required this.scale,
    required this.sizeHintMB,
    required this.channels,
    this.inputZero255 = false,
    required this.tileIn,
    required this.tilePad,
    this.inputAlign = 1,
    this.bundledAssetPath,
    required this.defaultUrls,
    this.sha256,
  });

  /// 支持的输出倍数（细调）：原生倍数优先，>2 的模型可由输出缩小得到更低倍数
  /// （参考 localManga 的 output_scales：如 animevideov3 4× 推理后缩小为 3×/2×）。
  List<int> get supportedOutputScales =>
      scale >= 4 ? const [4, 3, 2] : [scale];
}

/// 把用户选择的输出倍数解析为有效值：0/非法值回退到模型原生倍数。
int resolveOutputScale(UpscaleModelDef def, int raw) {
  if (raw > 0 && def.supportedOutputScales.contains(raw)) {
    return raw;
  }
  return def.scale;
}

class UpscaleModels {
  UpscaleModels._();

  /// 模型注册表。顺序即 UI 展示顺序；默认选中 ACNet（内置、离线可用、速度最快）。
  static const List<UpscaleModelDef> all = [
    UpscaleModelDef(
      id: 'anime4k_acnet',
      fileName: 'anime4k_acnet.onnx',
      displayName: 'Anime4K ACNet (2×)',
      description: 'Official Anime4K v4 ACNet, lightweight and fast, anime 2x, works offline',
      scale: 2,
      sizeHintMB: 1,
      channels: 1,
      tileIn: 384,
      tilePad: 16,
      bundledAssetPath: 'assets/models/anime4k_acnet.onnx',
      defaultUrls: [
        'https://ghproxy.net/https://github.com/Kiastr/Venera-SSR/releases/download/model/anime4k_acnet.onnx',
        'https://github.com/Kiastr/Venera-SSR/releases/download/model/anime4k_acnet.onnx',
      ],
    ),
    UpscaleModelDef(
      id: 'anime4k_x4',
      fileName: 'realesr_animevideov3.onnx',
      displayName: '动画 4× (Real-ESRGAN)',
      description: 'Real-ESRGAN animevideov3, fast, anime video 4x',
      scale: 4,
      sizeHintMB: 3,
      channels: 3,
      tileIn: 384,
      tilePad: 16,
      defaultUrls: [
        'https://ghproxy.net/https://github.com/Kiastr/Venera-SSR/releases/download/model/realesr_animevideov3.onnx',
        'https://github.com/Kiastr/Venera-SSR/releases/download/model/realesr_animevideov3.onnx',
        'https://hf-mirror.com/skillsafe-ai/realesr-animevideov3/resolve/main/model.onnx',
        'https://huggingface.co/skillsafe-ai/realesr-animevideov3/resolve/main/model.onnx',
      ],
    ),
    UpscaleModelDef(
      id: 'mangajanai_1600p_2x',
      fileName: 'mangajanai_1600p_2x.onnx',
      displayName: '黑白漫画 2× (MangaJaNai)',
      description: 'MangaJaNai V1, trained for B/W manga, text and halftone, 2x (large, slower)',
      scale: 2,
      sizeHintMB: 65,
      channels: 3,
      tileIn: 384,
      tilePad: 16,
      sha256: '214a387e64a71c1e41751453269ee2ff1ee9f33b32429c615dc7ea91238d9ee0',
      defaultUrls: [
        'https://hf-mirror.com/haesslerian/MangaJaNai_V1_ONNX/resolve/2f67ff30209f2e0c75b7c55e6f3ffc3adbc960f7/2x_MangaJaNai_1600p_V1_ESRGAN_90k.onnx',
        'https://huggingface.co/haesslerian/MangaJaNai_V1_ONNX/resolve/2f67ff30209f2e0c75b7c55e6f3ffc3adbc960f7/2x_MangaJaNai_1600p_V1_ESRGAN_90k.onnx',
      ],
    ),
    UpscaleModelDef(
      id: 'waifu2x_cunet_x2',
      fileName: 'waifu2x_cunet_art_scale2x.onnx',
      displayName: 'Waifu2x CUNet (2×)',
      description: 'Classic Waifu2x CUNet, anime illustration lines and halftone, 2x (slower)',
      scale: 2,
      sizeHintMB: 5,
      channels: 3,
      tileIn: 256,
      tilePad: 24,
      inputAlign: 4,
      defaultUrls: [
        'https://hf-mirror.com/deepghs/waifu2x_onnx/resolve/main/20230131/onnx_models/cunet/art/scale2x.onnx',
        'https://huggingface.co/deepghs/waifu2x_onnx/resolve/main/20230131/onnx_models/cunet/art/scale2x.onnx',
      ],
    ),
    UpscaleModelDef(
      id: 'waifu2x_swin_x2',
      fileName: 'waifu2x_swin_art_scale2x.onnx',
      displayName: 'Waifu2x SwinIR (2×)',
      description: 'Waifu2x with SwinIR architecture, stronger details, 2x (slow)',
      scale: 2,
      sizeHintMB: 17,
      channels: 3,
      tileIn: 256,
      tilePad: 24,
      inputAlign: 8,
      defaultUrls: [
        'https://hf-mirror.com/deepghs/waifu2x_onnx/resolve/main/20230131/onnx_models/swin_unet/art/scale2x.onnx',
        'https://huggingface.co/deepghs/waifu2x_onnx/resolve/main/20230131/onnx_models/swin_unet/art/scale2x.onnx',
      ],
    ),
    UpscaleModelDef(
      id: 'general_x4v3',
      fileName: 'realesr_general_x4v3.onnx',
      displayName: '通用 4× (Real-ESRGAN)',
      description: 'Real-ESRGAN general-x4v3, universal for photos and color pages, 4x',
      scale: 4,
      sizeHintMB: 5,
      channels: 3,
      tileIn: 384,
      tilePad: 16,
      defaultUrls: [
        'https://hf-mirror.com/CoderViking/realesr-general-x4v3-onnx/resolve/main/realesr-general-x4v3.onnx',
        'https://huggingface.co/CoderViking/realesr-general-x4v3-onnx/resolve/main/realesr-general-x4v3.onnx',
        'https://hf-mirror.com/ano_test/realesr-general-x4v3.onnx/resolve/main/realesr-general-x4v3.onnx',
        'https://huggingface.co/ano_test/realesr-general-x4v3.onnx/resolve/main/realesr-general-x4v3.onnx',
      ],
    ),
  ];

  static UpscaleModelDef byId(String id) =>
      all.firstWhere((m) => m.id == id, orElse: () => all.first);
}
