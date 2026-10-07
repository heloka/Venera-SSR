# 交接文档：Venera-SSR AI 超分功能改造（2026-10-07）

> 写给下一个接手的 AI / 开发者。§1–§9 记录旧版本的 ONNX 实现；当前 Windows
> 实现、参数、迁移与交付状态以 §10 为准。

---

## 0. 一句话背景

Venera-SSR（Flutter 漫画阅读器）原有的「v4 AI 超分」仅 Android 可用
（Kotlin + ONNX Runtime + NNAPI），用户在 Windows 上开启后表现为"超分失败"。
本次改造：为桌面端（Windows/Linux/macOS）实现跨平台 ONNX 超分引擎，
并对齐用户自己的参考项目 **localManga**（`D:\04_Work_Learning\Projects\Vibe\localManga`，
Web 前端 + Python 后端，`server/upscale/` 是超分引擎）的推理行为与交互。

**用户对效果的最终验收标准：与 localManga 里的超分效果一致。**

- 用户的 fork（构建与发布在这里）：https://github.com/heloka/Venera-SSR
- 上游原仓库：https://github.com/Kiastr/Venera-SSR
- 本地仓库：`D:\04_Work_Learning\Projects\Venera-SSR`（remote `origin`=上游，
  remote `fork`=用户的 fork；分支 main）

## 1. 三轮改动概览（按时间序）

| 轮次 | commit | 内容 |
|---|---|---|
| 1 | `3d7563d` | 桌面端 ONNX 超分引擎（onnxruntime Dart FFI 插件）+ 模型注册表 + 下载管理 + 设置页；修复 CI Flutter 版本不匹配；Android so 冲突 pickFirst |
| 2 | `c2ddeae` | 阅读器实时超分面板/对比原图/左下角状态胶囊/任务面板/输出倍数细调 |
| 3 | `67b598f`（当前 HEAD） | **引擎行为对齐 localManga**：超长边页跳过保持原图、默认模型 animevideov3 输出 2×、分块方案改为核心512+重叠16+补偶数、删 intensity、删阅读器✨按钮与快捷面板（对比开关移入任务面板）、模型集收窄 |

第 3 轮是用户反馈"效果完全不如 localManga"后的重构，**根因**有二：
- 旧引擎对超长边页面做"缩小到上限再超分"，localManga 是**跳过保持原图**（skipped 策略）——
  缩小再放大是大页面变模糊的主因；
- 旧默认模型是较弱的 ACNet，localManga 默认 `realesr-animevideov3` 输出 2×。

## 2. 当前架构与文件清单

```
lib/utils/anime4k/
├── upscale_models.dart          # 模型注册表（纯 Dart，无 Flutter 依赖）
├── ort_upscale_core.dart        # 分块推理核心（纯 Dart）：tile/跳过/倍数细调/alpha
├── ort_upscale_worker.dart      # 常驻 isolate：会话只加载一次、进度/跳过/错误消息协议
├── upscale_status_tracker.dart  # 任务状态追踪（ChangeNotifier 单例）：排队/处理/完成/跳过/失败
├── anime4k_v4_service.dart      # v4 服务：缓存+队列+平台路由（Android原生 / 桌面worker）
├── anime4k_v4_model_manager.dart# 模型生命周期：内置抽取/下载(镜像+sha256)/自选模型
├── anime4k_service.dart         # v1 纯 Dart CPU 算法（旧有，未动；接入了状态追踪）
└── anime4k_upscaler.dart        # v1 算法实现（旧有，未动）

lib/pages/reader/
├── upscale_panel.dart           # part of reader.dart：左下角状态胶囊 + 任务面板 + 对比原图开关
├── scaffold.dart                # Stack 里挂了 _UpscaleStatusPill（left:16, bottom:44）
├── images.dart                  # _createImageProviderFromKey 传 compareOriginal
└── comic_image.dart             # 旧有 ComicImage（imageCache 清理/重载入口 ComicImage.clear()）

lib/foundation/image_provider/reader_image.dart  # 处理管线入口：AI处理在 ImageProvider.load 内
lib/pages/settings/anime4k.dart                  # 超分完整设置页（part of settings_page.dart）
doc/anime4k_v4_upscale.md                        # 引擎技术文档（含关键坑）
```

### 数据流（桌面端）

```
ReaderImageProvider.load()
  ├─ compareOriginal=true → 直接返回原始字节（跳过全部 AI 处理）
  ├─ v4 且 Anime4KV4Service.isAvailable
  │    → Anime4KV4Service.processImage(cacheKey, outputScale, label:'第 N 页')
  │        → 缓存命中直接返回
  │        → 入队（maxConcurrent=2）→ tracker.enqueue/start
  │        → Android: MethodChannel colorize/esrgan（原生 NNAPI→CPU 回退）
  │             超过 maxEdge 先 _checkSkip 抛 UpscaleSkippedException
  │        → 桌面: OrtUpscaleWorker.run（常驻 isolate，core 512+重叠16+补偶）
  │             长边超限 → worker 回 skipped 事件 → tracker「已跳过」→ 返回 null（显示原图）
  │        → outputScale < 原生倍数时缩小（桌面在编码前 / Android 在 isolate 后处理）
  │        → 磁盘缓存（tmp/anime4k_v4_cache/<key.hashCode>.png）
  └─ 否则 v1（Anime4KService，纯 Dart 算法）
```

### 设置键（appdata.settings）

| 键 | 默认 | 语义 |
|---|---|---|
| `enableAnime4K` | false | 总开关（reader settings 可按漫画覆盖） |
| `anime4KVersion` | 'v1' | 'v1' 纯算法 / 'v4' AI 模型 |
| `anime4KV4MaxEdge` | 1600 | 输入长边上限；**超过则跳过超分保持原图**（对齐 localManga），0=不限制 |
| `anime4KV4Scale` | 2 | 输出倍数细调；0=模型原生；4x 模型可选 4/3/2（低倍=推理后缩小） |
| `anime4KV4Model` | (prefs) | 选中模型 id，默认注册表顺序第一个已下载的…实际代码默认 `'anime4k_x4'` |

v4 磁盘缓存键：`v4_<modelId>_s<effScale>_e<maxEdge>_<cacheKey>`
（v1 键：`<cacheKey>_<scale>_<push>_<grad>`；intensity 已废弃不用，键里已无）

## 3. 关键技术事实与坑（接手必读）

1. **`OrtSession.fromFile` 在 Windows 必然失败**：ORT 的 Windows 构建 `ORTCHAR_T=wchar_t`，
   而插件传 UTF-8 窄字符路径。**必须用 `OrtSession.fromBuffer`**（读入内存建会话）。
   引擎里 `createOrtSession()` 已封装，别改回 fromFile。
2. **`OrtValueTensor.createTensorWithDataList` 的类型推断**：必须传 `[float32List]`
   （嵌套一层）才是 float32；直接传 `Float32List` 会被当成 float64。
3. **可变分块下输出是矩形**：输出尺寸要从张量嵌套结构下探取 H/W
   （`_flattenTensor` 已实现），不能 `sqrt(len/channels)`。
4. **只支持"输出 = 输入×原生倍数"的模型**（ESRGAN/SRVGGNetCompact/ACNet 家族）。
   waifu2x cunet/swin 是 valid-conv（输出比输入×2小36px），localManga 用 ncnn 处理，
   Dart 引擎不收录（曾收录后移除，避免裁剪偏差）。
5. **MangaJaNai 输入边长必须是偶数**（pixel-unshuffle），用边缘复制补齐
   （等价 `np.pad(mode='edge')`），见 `inputMultiple: 2`。
6. **跳过策略是效果的核心**：长边超限的页必须保持原图，不要改成"缩小再超分"。
7. **插件 `onnxruntime: 1.4.1`（gtbluesky）自带各平台动态库**，Windows 下由 CMake
   `bundled_libraries` 自动把 `onnxruntime.dll` 部署到 exe 旁（纯 Dart FFI，无原生代码）。
   包本体依赖 Flutter SDK，纯 Dart 环境用需打补丁（见 §5 harness）。
8. **Android 打包冲突**：原生 `onnxruntime-android` 与 Dart 插件都带 `libonnxruntime.so`，
   `android/app/build.gradle` 已加 `packagingOptions { jniLibs { pickFirsts += ['lib/**/libonnxruntime.so'] } }`，
   Android 推理只走原生通道，删掉会构建失败。
9. **pubspec 固定 `flutter: 3.38.5`（精确版本）**，CI 已对齐 3.38.5。
   若升 Flutter 必须同步改 pubspec environment + 5 个 workflow 文件
   （`.github/workflows/{Windows,Linux,Mac,Ios}dart.yml` + `build_apk.yml`）。
10. **用户 fork 的 push 不会自动触发 workflow**（GitHub 对 fork 的限制）。
    触发方式二选一：
    - Actions 页 → Build Windows → **Run workflow** 按钮；
    - API：`POST /repos/heloka/Venera-SSR/actions/workflows/Windowsdart.yml/dispatches` + `{"ref":"main"}`（204=成功）。
11. **本机不能构建 Windows 包**：VS 2022 BuildTools 缺 CMake 工具与 Windows SDK 组件
    （flutter doctor 可复现）。构建一律走 CI。
12. 本机临时验证环境（**在 TEMP 下，可能被系统清理**，丢了按 §5 重建）：
    - Flutter SDK 3.38.5：`C:\Users\atri\AppData\Local\Temp\flutter_sdk_dir\flutter`
    - Dart SDK 3.9.4：`C:\Users\atri\AppData\Local\Temp\dart-sdk-dir\dart-sdk`
    - 引擎验证 harness：`C:\Users\atri\AppData\Local\Temp\ort_harness`
      （内含打补丁的纯 Dart 版 onnxruntime 包 `../ort_pkg_dart` + 已下载模型 `models/`）
    - GitHub API 脚本：`C:\Users\atri\AppData\Local\Temp\gh_api.sh`（用 git credential 里的令牌，勿回显）

## 4. 与 localManga 的对齐关系（参考实现，用户是作者）

参考代码：`D:\04_Work_Learning\Projects\Vibe\localManga\server\upscale\`
（`engine.py` 推理核心 / `catalog.py` 模型目录 / `scheduler.py` 调度与跳过 / `runtime.py` 路由）

| 行为 | localManga | Venera 现状 | 一致性 |
|---|---|---|---|
| 输入归一化 | `/255` float32 NCHW | 同 | ✅ |
| 分块 | 核心512+每侧重叠16，边缘收拢，补 inputMultiple | 同（模型注册表参数化） | ✅ |
| 超长边策略 | skipped，保持原图 | 同（抛 UpscaleSkippedException→显示原图） | ✅ |
| 默认模型/倍数 | realesr-animevideov3，输出 2× | 同 | ✅ |
| 倍数细调 | output_scales，推理后 LANCZOS 缩小 | 同（image 包无 lanczos，用 cubic） | ≈ |
| intensity/对比缩放 | 无 | 已移除 | ✅ |
| TTA/mix_ratio/denoise | 有（ncnn 模型系） | 未实现（默认关闭/100，不影响默认效果） | ❌ 按需 |
| GPU | onnxruntime-directml | 仅 CPU（插件 dll 是 CPU 版） | ❌ 速度差，画质同 |
| MangaJaNai 模型 | `haesslerian/MangaJaNai_V1_ONNX` pinned commit，sha256 校验 | 同一文件同一 sha256 | ✅ |
| Real-CUGAN/waifu2x | ncnn bundle（外部 exe） | 未收录（无可靠 ONNX） | ❌ 有意为之 |

模型 URL 都写在 `upscale_models.dart` 的 `defaultUrls`（镜像在前：ghproxy/hf-mirror → 官方源）。
MangaJaNai sha256：`214a387e64a71c1e41751453269ee2ff1ee9f33b32429c615dc7ea91238d9ee0`。

## 5. 验证方法

```bash
# Flutter 侧（用临时 SDK；若无则重下 https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.38.5-stable.zip）
flutter pub get
flutter analyze          # 应 0 error（现存 11 条 info/warning 均为旧代码遗留）
flutter test             # 17 个测试应全过（test/anime4k_test.dart + channel_test.dart）

# 引擎真模型验证（harness，绕过 Flutter 直接跑仓库的纯 Dart 核心）
cd %TEMP%/ort_harness
# 把仓库 lib/utils/anime4k/{ort_upscale_core,upscale_models}.dart 拷到 lib/src_copy/ 覆盖
../dart-sdk-dir/dart-sdk/bin/dart.exe pub get
../dart-sdk-dir/dart-sdk/bin/dart.exe bin/test_localmanga.dart
# 期望：MangaJaNai 700x451(奇数页) → 1400x902 无接缝；2000x3000 页 @1600 上限抛 skipped；
#       animevideov3 outputScale null/3/2 → 1200x868 / 900x651 / 600x434
```

harness 的 `models/` 里已有：anime4k_acnet / realesr_animevideov3 /
mangajanai_1600p_2x / realesr_general_x4v3（waifu2x 两个已弃用可删）。
打补丁的 onnxruntime 包在 `%TEMP%/ort_pkg_dart`（原包拷贝后删除 pubspec 的 flutter 依赖、
plugin 段、topics 段，和 `lib/src/ort_session.dart` 的 `package:flutter/services.dart` import）。

## 6. 当前状态

- 本地 main = `67b598f`，已推送 fork；CI Build Windows 三连绿
  （最新 run：`37582712406`，产物 `Venera-Windows-v2.1.5.zip` 23.5MB，2027-01-05 过期）。
- 分析器 0 错误；测试 17/17 通过；真模型验证全绿（含目测接缝）。
- 用户已反馈的体验项均已实现：状态胶囊（超分中/排队/已处理/已跳过，可点开任务面板）、
  对比原图（任务面板顶部开关，原图/超分图双变体共存 imageCache 秒切）、
  输出倍数细调、实时生效（改设置即清 imageCache + ComicImage.clear()）。

## 7. 已知限制与可能的后续方向

1. **桌面只有 CPU 推理**：DirectML 需要把 `windows/onnxruntime.dll` 换成 DML 构建
   （Microsoft onnxruntime-directml 发布包）并注册 DML EP；插件 API 未暴露 EP 配置，
   需要自写少量 FFI 或换 `flutter_onnxruntime` 包。收益：MangaJaNai 从 ~30s/页 → 秒级。
2. **Real-CUGAN / waifu2x 未收录**：无可靠 ONNX；若必须要，路线是像 localManga 那样
   内置 ncnn-vulkan CLI 外部进程（架构完全不同，需单独设计）。
3. **TTA / mix_ratio / denoise 未实现**（localManga 有；默认配置下不影响效果）。
4. iOS/macOS CI 带上新插件后未验证过构建（iOS pod 依赖 `onnxruntime-objc 1.15.1`）。
5. Windows ARM64：插件的 dll 是 x64，加载失败会优雅回退 v1（无崩溃）。
6. AI 上色（Colorization）仍是 Android 专属，本次未动。
7. v1 算法（anime4k_service/anime4k_upscaler）完全未动。
8. fork 的 `publish_release.yml`（workflow_run 触发）在 fork 上没跑过——Release 附件
   一直没自动生成，产物在 Actions run 页面下载。可排查或手动发 Release。

## 8. 常用操作

```bash
# 提交推送（remote 名叫 fork）
git add -A && git commit -m "..." && git push fork main

# 触发 Windows 构建（fork 不自动触发）
curl -X POST -H "Authorization: Bearer <token>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/heloka/Venera-SSR/actions/workflows/Windowsdart.yml/dispatches \
  -d '{"ref":"main"}'
# token 来源：git credential fill（本机 GCM 已存）；或 Actions 页 Run workflow 按钮

# 查状态 / 产物
curl -s https://api.github.com/repos/heloka/Venera-SSR/actions/runs?per_page=5
# 产物在 run 页面底部 Artifacts，命名 Venera-Windows-v<版本>.zip
```

## 9. 相关翻译键（assets/translation.json，zh_CN/zh_TW 两节）

超分相关新增键都以英文原文为 key（`.tl` 精确匹配）：`AI Upscale` / `Upscale Tasks` /
`Compare Original` / `Output Scale` / `Max Input Edge` / `Native` / `Downscaled` /
`Waiting in queue` / `Upscaling` / `Processed` / `Skipped` / `Failed` / `Queued` /
`Unlimited` / `No upscale tasks yet` 等，以及 6 个模型 description 全文。

## 10. 当前 Windows 实现：Real-CUGAN Vulkan（2.1.6）

本节覆盖旧 Windows ONNX/CPU 说明。Flutter 版本仍固定为 3.38.5。

### 引擎、模型和依赖

- Windows 默认后端为 `realcugan-ncnn-vulkan 20220728`，随便携包放在 exe 旁的
  `upscale/` 目录。该后端调用 Vulkan；不需要 Python、CUDA 或 PyTorch。
- 上游发行 ZIP 的 SHA-256 固定为
  `c6e08d46c11704b1e3a1ada9ddd591cb5005f52f132136c8633ba25def400e01`。
  `scripts/prepare_windows_upscale.ps1` 校验哈希、SE/Pro 权重、`vcomp140.dll` 和许可证，
  然后生成与应用校验值匹配的 `realcugan-manifest.json`。
- 默认模型是 SE、2×、`-1` 保守降噪、关闭 TTA、GPU 编号 0。SE 支持 2×/3×/4×；
  Pro 支持 2×/3×。降噪按型号能力限制，接缝同步默认快速；GPU 任务串行。
- GPU 初始化失败时显示原图和具体错误，不回退 CPU。旧 ONNX 模型仍在“高级 CPU 模型”中，
  仅作为兼容入口，标签明确标记 CPU。

### 配置、阅读器与缓存

- `upscaleConfig` 是 Windows 超分配置快照，`upscaleConfigVulkanMigration: 1` 记录一次性迁移。
  迁移保留旧开关、长边上限（0 表示不限制）、旧 ONNX 模型选择和漫画专属覆盖；
  新模型默认切换到 Real-CUGAN SE。每个任务固定使用提交时的配置。
- 阅读器底栏提供超分开关、原图对比、设置入口和任务状态。点击阅读器后控件显示 5 秒，期间
  有交互时重置计时，超时后随顶栏和底栏淡出；超分控件位于统一底栏，不遮挡页码进度。
  横向画廊模式提供双页切换，按当前屏幕方向在每屏 1 张与 2 张之间切换；设置页仍允许高级调整
  每屏 1–5 张。对比只绕过超分，仍运行自定义图片处理及上色；关闭超分后仍可进入设置。
  漫画专属配置跟随阅读器当前漫画/来源。
- 缓存键包含引擎版本、输出参数、图片身份及源图片 SHA-256；结果是 PNG，配置之间隔离，
  写入采用临时文件原子替换，缓存上限 5 GiB。
- GPU 显存不足时，自动减小分块重试一次；单次进程最多 5 分钟。取消章节/设置变更任务，
  失败任务可在任务面板重试。面板记录实际 GPU 名称、耗时和输出尺寸。
- 参数面板支持 TTA、降噪、接缝同步、分块、混合比例、GPU 编号、输入长边限制和提前处理页数。

### 本机验证和交付

- 本机 RX 9070 XT 的实测使用了 `-g 0`，日志显示 `[0 AMD Radeon RX 9070 XT]`：
  Real-CUGAN SE 和 Pro 在同一漫画页分别约 1.3 秒和 1.0 秒，输出 1668×2400。
  这验证了引擎能使用本机 Vulkan GPU；不是应用便携包的最终验收。
- 本次交付提交为 `307f08196aa2e8ba184f9a6307ab93c1ee9ada3e`。GitHub Actions 已通过
  `flutter analyze`、`flutter test`、Windows Release 构建、引擎/模型暂存及完整性校验。
  [构建记录](https://github.com/heloka/Venera-SSR/actions/runs/37597661376)；产物为
  `Venera-Windows-v2.1.6.zip`（artifact `11471632889`）。包 SHA-256：
  `7469a2fd40ad5cd8252ff4e4b1f7a25ac21912fed9b0b62653c6774d9cca1843`。
- 已安装到 `D:\02_Software_Repo\PC_Tools\Venera-SSR-v2.1.6-windows`，未覆盖 v2.1.5。
  安装包含 `venera.exe`、Real-CUGAN Vulkan 引擎和 SE/Pro 权重；本次未启动应用。
- 首次启动前已备份 `%APPDATA%\com.github.wgh136\venera` 中的配置文件到
  `D:\02_Software_Repo\PC_Tools\Venera-SSR-v2.1.6-config-backup-20261007-171606`：
  `appdata.json`、`implicitData.json`、`shared_preferences.json` 和 `window_placement`。
  原目录中没有 `syncdata.json`，因此未备份该文件。
- RX 9070 XT 上已用同一上游引擎直接运行 SE/Pro：日志识别到 GPU，单页分别约 1.3/1.0 秒；
  这不是新版应用的端到端验收。当前尚未用便携包完成真实漫画阅读测试，也未验证所有倍率、
  中文路径、透明/奇数尺寸、显存不足恢复、开关/对比和缓存复用；需要在本机继续验收。

### 闪退排查和热修（2026-10-07）

- 用户在 SE 开启超分时遇到闪退。当前配置记录漫画专属项 `hunhuan@copy_manga`：SE、2×、
  长边上限 1600、超分已开启。应用日志没有写出 Real-CUGAN 异常，Windows 也没有匹配到
  `venera.exe` 的应用崩溃事件。
- 崩溃遗留的临时目录包含完整 `output.png`（1626×2400）。用同一 `input.png` 在便携包目录
  直接执行 SE GPU 命令成功，设备日志为 `[0 AMD Radeon RX 9070 XT]`，输出 SHA-256 与遗留图一致。
  因此引擎推理本身成功；具体是哪一步导致应用退出仍未确定。
- Windows 事件日志当天多次记录 `LiveKernelEvent`、`P1=141`（16:07 和 16:50，早于这次报告）。
  这提示可能存在显卡驱动/引擎超时，但不能据此认定它就是本次应用闪退原因。
- 热修提交 `8e55379566826ce69e6cfbc4cc8a71ccf17dffcf` 对默认 100% 混合、无透明通道图片，
  直接复用引擎 PNG，并校验 PNG 头和输出尺寸，避免再完整解码、复制和重新编码输出图。
  Flutter 分析、测试、Windows Release 构建及模型打包均通过。
- [热修构建记录](https://github.com/heloka/Venera-SSR/actions/runs/37601158525)，artifact
  `11473800681`，包 SHA-256：
  `36b7fe0ef95dbbea9209dbb59da7e58d00fb1789891c15e4a6862747071d69df`。
  热修包并排安装在
  `D:\02_Software_Repo\PC_Tools\Venera-SSR-v2.1.6-hotfix-8e55379-windows`；未启动应用，
  需由用户验证同一漫画页面能否正常显示。

### 第二轮复测和诊断热修（2026-10-07）

- 用户确认触发动作是开启超分开关后页面处理时闪退。第二轮热修版运行后仍失败；最近三次
  临时目录均留下完整 `output.png`，但 `upscale-vulkan-v1` 缓存为空。最新输入页再次通过
  SE GPU 直跑，设备识别为 RX 9070 XT，输出与应用遗留图 SHA-256 完全相同。应用日志仍无
  Real-CUGAN 错误或阶段记录，Windows 未记录对应的 `venera.exe` 崩溃。
- 第三版提交 `e0bda49a8b48d6978b952c311b89b3ad92a6b742` 在输入转换时按 alpha 像素实际值判断
  是否透明；100% 混合且没有透明像素时直接返回引擎 PNG。透明像素仍走保留 alpha 的合成流程。
  同时将最近阶段同步写入 `upscale-vulkan-v1/last-upscale-stage.txt`：`engine-exited`、
  `png-validated`、`postprocess-complete`、`cache-written`，用于在进程异常退出后确定最后完成步骤。
- [第三版 CI](https://github.com/heloka/Venera-SSR/actions/runs/37621075949) 已通过分析、测试、
  Windows 构建和模型打包。artifact `11482359431`，包 SHA-256：
  `97faaceb55fef0edac23b64dc270747a1fbadaeccdb7870230e93da9f63cd4b2`。
  已安装到 `D:\02_Software_Repo\PC_Tools\Venera-SSR-v2.1.6-diagnostic-e0bda49-windows`，
  未启动；要验证时应使用该目录中的 `venera.exe`，不要再用前两版 v2.1.6。

### 阅读器双页与工具栏修正（2026-10-07）

- `348e3d8` 加入阅读器横向画廊双页按钮；按钮按当前方向切换每屏 1/2 张，并保留每屏 1–5 张的
  高级设置。阅读器控件在点击后显示 5 秒；操作会重置计时，随后与页码进度栏一起淡出。
  超分开关、对比、设置和任务状态已移到底栏，不再覆盖页面进度。
- `4748915` 修正双页设置的保存调用。该提交已通过 Flutter 分析、测试、Windows Release 构建和
  Real-CUGAN 运行时打包。[CI 记录](https://github.com/heloka/Venera-SSR/actions/runs/37626803727)。
  产物为 `Venera-Windows-v2.1.6.zip`（artifact `11484853015`）。
