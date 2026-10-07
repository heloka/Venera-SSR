part of 'settings_page.dart';

class WindowsUpscaleSettingsPanel extends StatefulWidget {
  const WindowsUpscaleSettingsPanel({this.comicId, this.sourceKey, super.key});

  final String? comicId;
  final String? sourceKey;

  @override
  State<WindowsUpscaleSettingsPanel> createState() =>
      _WindowsUpscaleSettingsPanelState();
}

class _WindowsUpscaleSettingsPanelState
    extends State<WindowsUpscaleSettingsPanel> {
  UpscaleConfig _config = const UpscaleConfig();
  bool _ready = false;
  bool _runtimeAvailable = false;
  Timer? _saveTimer;

  bool get _isComicSetting =>
      widget.comicId != null && widget.sourceKey != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await RealCuganUpscaler.loadConfig(
      comicId: widget.comicId,
      sourceKey: widget.sourceKey,
    );
    final runtime = await RealCuganUpscaler.instance.isRuntimeAvailable();
    if (!mounted) return;
    setState(() {
      _config = config;
      _runtimeAvailable = runtime;
      _ready = true;
    });
  }

  Future<void> _save(UpscaleConfig config, {bool debounce = false}) async {
    final normalized = UpscaleConfig.fromJson(config.toJson());
    _saveTimer?.cancel();
    if (mounted) setState(() => _config = normalized);
    if (debounce) {
      _saveTimer = Timer(
        const Duration(milliseconds: 250),
        () => unawaited(_persist(normalized)),
      );
      return;
    }
    await _persist(normalized);
  }

  Future<void> _persist(UpscaleConfig config) async {
    await RealCuganUpscaler.saveConfig(
      config,
      comicId: widget.comicId,
      sourceKey: widget.sourceKey,
    );
    PaintingBinding.instance.imageCache.clear();
    ComicImage.clear();
  }

  @override
  void dispose() {
    if (_saveTimer?.isActive == true) {
      _saveTimer!.cancel();
      unawaited(_persist(_config));
    }
    super.dispose();
  }

  Future<void> _selectLegacyModel(String modelId) async {
    await Anime4KV4Service.instance.setModel(modelId);
    appdata.settings['anime4KVersion'] = 'v4';
    appdata.settings['anime4KV4Model'] = modelId;
    await _save(
      _config.copyWith(modelId: 'legacy:$modelId', legacyModelId: modelId),
    );
  }

  Widget _section(String title, Widget content) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        content,
      ],
    ),
  );

  Widget _choices(
    String title,
    List<int> choices,
    int value,
    ValueChanged<int> onChange, {
    String Function(int value)? label,
  }) => _section(
    title,
    Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final choice in choices)
          ChoiceChip(
            label: Text(label?.call(choice) ?? '$choice'),
            selected: value == choice,
            onSelected: (_) => onChange(choice),
          ),
      ],
    ),
  );

  Widget _slider(
    String title,
    int value,
    int max,
    String unit,
    void Function(int value, bool isFinal) onChange,
  ) => _section(
    '$title: $value$unit',
    Slider(
      value: value.toDouble(),
      min: 0,
      max: max.toDouble(),
      divisions: max,
      onChanged: (value) => onChange(value.round(), false),
      onChangeEnd: (value) => onChange(value.round(), true),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Center(child: CircularProgressIndicator());
    final scales = _config.supportedScales;
    final legacyModels = UpscaleModels.all;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          title: Text('Enable Upscaling'.tl),
          value: _config.enabled,
          onChanged: (enabled) => _save(_config.copyWith(enabled: enabled)),
        ),
        _section(
          'AI Upscale'.tl,
          Text(
            _config.isLegacy
                ? UpscaleModels.byId(_config.selectedModelId).displayName
                : _config.displayModel,
          ),
        ),
        _section(
          'Vulkan GPU Backend'.tl,
          Row(
            children: [
              Icon(
                _runtimeAvailable ? Icons.check_circle : Icons.error_outline,
                color: _runtimeAvailable ? Colors.green : Colors.redAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _runtimeAvailable
                      ? '${'Vulkan GPU'.tl} ${_config.gpuId} · Real-CUGAN 20220728'
                      : 'Real-CUGAN engine or model missing'.tl,
                ),
              ),
            ],
          ),
        ),
        _section(
          'Model'.tl,
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Real-CUGAN SE'),
                selected: _config.modelId == 'real-cugan-se',
                onSelected: (_) => _save(
                  _config.copyWith(
                    modelId: 'real-cugan-se',
                    scale: 2,
                    denoise: -1,
                  ),
                ),
              ),
              ChoiceChip(
                label: const Text('Real-CUGAN Pro'),
                selected: _config.modelId == 'real-cugan-pro',
                onSelected: (_) => _save(
                  _config.copyWith(
                    modelId: 'real-cugan-pro',
                    scale: 2,
                    denoise: -1,
                  ),
                ),
              ),
            ],
          ),
        ),
        _choices(
          'Output Scale'.tl,
          scales,
          _config.scale,
          (scale) => _save(_config.copyWith(scale: scale, denoise: -1)),
          label: (scale) => '$scale×',
        ),
        if (!_config.isLegacy)
          _choices(
            'Denoise Level'.tl,
            _config.supportedDenoise,
            _config.denoise,
            (denoise) => _save(_config.copyWith(denoise: denoise)),
            label: (value) => switch (value) {
              -1 => 'Conservative'.tl,
              0 => 'No Denoise'.tl,
              _ => '$value',
            },
          ),
        if (!_config.isLegacy) ...[
          SwitchListTile(
            title: Text('TTA Flip Upscaling'.tl),
            value: _config.tta,
            onChanged: (tta) => _save(_config.copyWith(tta: tta)),
          ),
          _choices(
            'Seam Synchronization'.tl,
            const [0, 1, 2, 3],
            _config.syncgap,
            (syncgap) => _save(_config.copyWith(syncgap: syncgap)),
            label: (value) => switch (value) {
              0 => 'Off'.tl,
              1 => 'Accurate'.tl,
              2 => 'Rough'.tl,
              _ => 'Fast'.tl,
            },
          ),
          _choices(
            'Tile Size'.tl,
            const [0, 128, 192, 256, 320, 384, 512, 640, 768, 1024],
            _config.tileSize,
            (tileSize) => _save(_config.copyWith(tileSize: tileSize)),
            label: (value) => value == 0 ? 'Auto'.tl : '$value',
          ),
          _choices(
            'GPU Device'.tl,
            const [0, 1, 2, 3],
            _config.gpuId,
            (gpuId) => _save(_config.copyWith(gpuId: gpuId)),
          ),
        ],
        if (!_config.isLegacy) ...[
          _slider(
            'Enhanced Image Mix'.tl,
            _config.mixRatio,
            100,
            '%',
            (mixRatio, isFinal) =>
                _save(_config.copyWith(mixRatio: mixRatio), debounce: !isFinal),
          ),
          _choices(
            'Max Input Edge'.tl,
            const [0, 1200, 1600, 2048, 2560, 4096, 8192],
            _config.maxInputEdge,
            (maxInputEdge) =>
                _save(_config.copyWith(maxInputEdge: maxInputEdge)),
            label: (value) => value == 0 ? 'Unlimited'.tl : '${value}px',
          ),
        ],
        _slider(
          'Preloaded Pages'.tl,
          _config.preloadPages,
          64,
          '',
          (preloadPages, isFinal) => _save(
            _config.copyWith(preloadPages: preloadPages),
            debounce: !isFinal,
          ),
        ),
        if (!_isComicSetting) ...[
          _section(
            'Advanced CPU Models'.tl,
            Text('Windows legacy ONNX models use the CPU.'.tl),
          ),
          _section(
            'Model'.tl,
            Wrap(
              spacing: 8,
              children: [
                for (final model in legacyModels)
                  ChoiceChip(
                    label: Text(model.displayName),
                    selected: _config.isLegacy
                        ? _config.selectedModelId == model.id
                        : _config.legacyModelId == model.id,
                    onSelected: (_) => _selectLegacyModel(model.id),
                  ),
              ],
            ),
          ),
        ],
        if (UpscaleStatusTracker.instance.snapshot.isNotEmpty)
          _section(
            'Latest Upscale'.tl,
            Builder(
              builder: (context) {
                final job = UpscaleStatusTracker.instance.snapshot.first.value;
                return Text(
                  [
                    job.backendName ?? job.modelId,
                    if (job.elapsed != null) '${job.elapsed!.inMilliseconds}ms',
                    if (job.outputWidth != null && job.outputHeight != null)
                      '${job.outputWidth}×${job.outputHeight}',
                    if (job.error != null) job.error!,
                  ].join(' · '),
                );
              },
            ),
          ),
        ListTile(
          title: Text('Clear Upscale Cache'.tl),
          trailing: const Icon(Icons.delete_sweep),
          onTap: () async {
            await RealCuganUpscaler.instance.clearCache();
            await Anime4KV4Service.instance.clearCache();
            if (mounted)
              context.showMessage(message: 'Upscale cache cleared'.tl);
          },
        ),
      ],
    );
  }
}

/// Anime4K 设置页
///
/// 同时管理两个引擎版本：
///  - v1：纯 Dart CPU 算法（Gauss/Unblur/GradientRefine），缩放 1–4x，无模型文件；
///  - v4：AI 超分 ONNX 模型（Anime4K ACNet / Real-ESRGAN / MangaJaNai / Waifu2x 家族），
///    Android 走原生 ONNX Runtime + NNAPI(GPU)，Windows/Linux/macOS 走 onnxruntime Dart FFI
///    （常驻 isolate 分块推理，CPU）。
///
/// 两版本并存，由 `anime4KVersion` 设置选择；v4 选中时显示模型管理卡片，并隐藏 v1 专用滑块。
class Anime4KSettings extends StatefulWidget {
  const Anime4KSettings({super.key});

  @override
  State<Anime4KSettings> createState() => _Anime4KSettingsState();
}

class _Anime4KSettingsState extends State<Anime4KSettings> {
  bool _isModelDownloaded = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _status = '';
  String? _customModelName;
  List<String> _modelUrls = [];
  bool _usingCustom = false;

  @override
  void initState() {
    super.initState();
    _refreshModelStatus();
  }

  Future<void> _refreshModelStatus() async {
    final usingCustom = await Anime4KV4ModelManager.isCustomModelActive();
    final customName = await Anime4KV4ModelManager.getCustomModelName();
    final urls = await Anime4KV4ModelManager.getModelUrls();
    final downloaded = await Anime4KV4ModelManager.isModelDownloaded;
    if (mounted) {
      setState(() {
        _customModelName = customName;
        _modelUrls = urls;
        _isModelDownloaded = downloaded;
        _usingCustom = usingCustom;
      });
    }
  }

  String get _version => appdata.settings['anime4KVersion'] as String? ?? 'v1';

  /// v4 推理后端说明（按平台）
  String get _backendDescription {
    if (App.isAndroid) {
      return "Backend: ONNX Runtime + NNAPI (GPU), falls back to CPU on failure"
          .tl;
    }
    return "Backend: ONNX Runtime (CPU, tiled inference in background isolate)"
        .tl;
  }

  int get _maxEdge =>
      (appdata.settings['anime4KV4MaxEdge'] as num?)?.toInt() ?? 1600;

  int get _rawScale =>
      (appdata.settings['anime4KV4Scale'] as num?)?.toInt() ?? 0;

  void _setScale(int scale) {
    if (_rawScale == scale) return;
    appdata.settings['anime4KV4Scale'] = scale;
    appdata.saveData();
    PaintingBinding.instance.imageCache.clear();
    ComicImage.clear();
    setState(() {});
  }

  void _setVersion(String v) {
    if (_version == v) return;
    appdata.settings['anime4KVersion'] = v;
    appdata.saveData();
    // 切换引擎后强制刷新图片（v1/v4 输出不同，缓存不可复用）
    PaintingBinding.instance.imageCache.clear();
    ComicImage.clear();
    setState(() {});
  }

  /// 切换 v4 超分模型（4x/2x）。不同倍数输出尺寸不同，清缓存避免串图。
  Future<void> _selectModel(String id) async {
    if (Anime4KV4ModelManager.selectedDef.id == id) return;
    await Anime4KV4Service.instance.setModel(id);
    PaintingBinding.instance.imageCache.clear();
    ComicImage.clear();
    await _refreshModelStatus();
    if (mounted) setState(() {});
  }

  Future<void> _downloadModel() async {
    if (_isDownloading) return;
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _status = 'Preparing...';
    });

    try {
      await Anime4KV4ModelManager.downloadModel(
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _downloadProgress = progress;
              _status = 'Downloading ${(progress * 100).toStringAsFixed(1)}%';
            });
          }
        },
        onStatus: (status) {
          if (mounted) {
            setState(() {
              _status = status;
            });
          }
        },
      );
      if (mounted) {
        context.showMessage(message: "Model downloaded".tl);
      }
    } catch (e) {
      if (mounted) {
        context.showMessage(message: "Download failed: $e".tl);
      }
    } finally {
      _isDownloading = false;
      // 模型文件已变更，失效原生会话缓存并刷新服务路径缓存
      await Anime4KV4Service.instance.resetNativeSession();
      await Anime4KV4Service.instance.checkModelAvailable();
      await _refreshModelStatus();
      if (mounted) {
        setState(() {
          _status = _isModelDownloaded ? 'Ready' : '';
        });
      }
    }
  }

  Future<void> _deleteModel() async {
    await Anime4KV4ModelManager.clearModel();
    await Anime4KV4Service.instance.clearCache();
    // 让服务感知模型已删除（重置 _modelPath，校验文件不存在）
    await Anime4KV4Service.instance.resetNativeSession();
    await Anime4KV4Service.instance.checkModelAvailable();
    await _refreshModelStatus();
    if (mounted) {
      context.showMessage(message: "Model deleted".tl);
      setState(() {
        _status = '';
        _downloadProgress = 0.0;
      });
    }
  }

  /// 选择本地 .onnx 模型文件（优先级高于内置下载模型）
  Future<void> _pickLocalModel() async {
    try {
      final xFile = await file_selector.openFile(
        acceptedTypeGroups: <file_selector.XTypeGroup>[
          file_selector.XTypeGroup(label: 'ONNX Model', extensions: ['onnx']),
        ],
      );
      if (xFile == null) return;
      if (!xFile.name.toLowerCase().endsWith('.onnx')) {
        if (mounted)
          context.showMessage(message: "Please select a .onnx file".tl);
        return;
      }
      // Android 经原生 ContentResolver 以 64KB 分块拷贝（不占内存、不拷坏）；
      // 桌面端 xFile.path 即真实文件路径，直接用 dart:io 拷贝。
      // 均落到当前选中模型的调用位置（fileName）。
      final uri = xFile.path; // content URI 或真实文件路径
      final dir = await getApplicationSupportDirectory();
      final targetPath = path.join(
        dir.path,
        Anime4KV4ModelManager.modelFileName,
      );
      final bakPath = '$targetPath.bak';
      final tempPath = '$targetPath.tmp';

      // 已存在下载模型则先备份，便于“回退内置模型”还原
      final targetFile = File(targetPath);
      if (await targetFile.exists()) {
        await targetFile.rename(bakPath);
      }

      int written;
      try {
        if (App.isAndroid) {
          written = await Anime4KV4ModelManager.copyUriTo(uri, tempPath);
        } else {
          final srcFile = File(uri);
          if (!await srcFile.exists()) {
            throw Exception('file not found: $uri');
          }
          await srcFile.copy(tempPath);
          written = await File(tempPath).length();
        }
      } catch (e) {
        if (await File(bakPath).exists())
          await File(bakPath).rename(targetPath);
        if (mounted) context.showMessage(message: "Failed to copy file: $e".tl);
        return;
      }

      if (written < Anime4KV4ModelManager.validModelMinSize) {
        try {
          await File(tempPath).delete();
        } catch (_) {}
        if (await File(bakPath).exists())
          await File(bakPath).rename(targetPath);
        if (mounted)
          context.showMessage(message: "File too small, invalid model".tl);
        return;
      }

      await File(tempPath).rename(targetPath);
      try {
        await File(bakPath).delete();
      } catch (_) {}

      // 记账为自选模型 + 失效原生会话缓存 + 让服务立即感知新路径
      await Anime4KV4ModelManager.markCustomModelActive(xFile.name);
      await Anime4KV4Service.instance.resetNativeSession();
      await Anime4KV4Service.instance.checkModelAvailable();
      await _refreshModelStatus();
      if (mounted) context.showMessage(message: "Custom model selected".tl);
    } catch (e) {
      if (mounted) context.showMessage(message: "Failed to pick file: $e".tl);
    }
  }

  /// 清除自选模型，回退到内置（下载）模型
  Future<void> _clearCustomModel() async {
    await Anime4KV4ModelManager.clearCustomModelSelection();
    await Anime4KV4Service.instance.resetNativeSession();
    await Anime4KV4Service.instance.checkModelAvailable();
    await _refreshModelStatus();
    if (mounted) context.showMessage(message: "Reverted to built-in model".tl);
  }

  /// 添加一个自定义镜像 URL
  Future<void> _addMirrorUrl() async {
    await showInputDialog(
      context: context,
      title: "Add Mirror URL".tl,
      hintText: "https://.../${Anime4KV4ModelManager.modelFileName}",
      confirmText: "Add".tl,
      onConfirm: (url) async {
        await Anime4KV4ModelManager.addModelUrl(url);
        await _refreshModelStatus();
        return null as Object?;
      },
    );
  }

  /// 删除指定下标的镜像 URL
  Future<void> _removeMirrorUrl(int index) async {
    await Anime4KV4ModelManager.removeModelUrlAt(index);
    await _refreshModelStatus();
  }

  @override
  Widget build(BuildContext context) {
    if (App.isWindows) {
      return SmoothCustomScrollView(
        slivers: [
          SliverAppbar(title: Text('Upscale Settings'.tl)),
          SliverToBoxAdapter(child: WindowsUpscaleSettingsPanel()),
        ],
      );
    }
    final isV4 = _version == 'v4';
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Anime4K".tl)),
        _SwitchSetting(
          title: "Enable Anime4K Upscaling".tl,
          settingKey: "enableAnime4K",
          beforeChange: (newValue) async {
            // 关闭或 v1 直接放行
            if (!newValue) return true;
            if (_version != 'v4') return true;
            // v4 开启前必须确保模型已下载
            final downloaded = await Anime4KV4ModelManager.isModelDownloaded;
            if (downloaded) return true;
            if (!mounted) return false;
            final confirm = await showDialog<bool>(
              context: context,
              builder: (dialogContext) {
                return ContentDialog(
                  title: "Model Required".tl,
                  content: Text(
                    "Anime4K v4 model (${Anime4KV4ModelManager.selectedDef.displayName}) is not downloaded. Download (~${Anime4KV4ModelManager.selectedDef.sizeHintMB}MB) to enable?"
                        .tl,
                  ).paddingHorizontal(16).fixWidth(double.infinity),
                  actions: [
                    Button.filled(
                      onPressed: () => dialogContext.pop(true),
                      child: Text("Download".tl),
                    ),
                    Button.outlined(
                      onPressed: () => dialogContext.pop(false),
                      child: Text("Cancel".tl),
                    ),
                  ],
                );
              },
            );
            if (confirm == true) {
              await _downloadModel();
              if (mounted && await Anime4KV4ModelManager.isModelDownloaded) {
                appdata.settings['enableAnime4K'] = true;
                appdata.saveData();
                PaintingBinding.instance.imageCache.clear();
                ComicImage.clear();
                setState(() {});
              }
            }
            // 由上面的手动置位控制开关，拦截这次手势
            return false;
          },
        ).toSliver(),
        // 引擎版本选择
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              "Engine Version".tl,
              style: TextStyle(
                color: context.colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: Text("v1 (CPU)".tl),
                  selected: !isV4,
                  onSelected: (_) => _setVersion('v1'),
                ),
                ChoiceChip(
                  label: Text("v4 (AI)".tl),
                  selected: isV4,
                  onSelected: (_) => _setVersion('v4'),
                ),
              ],
            ),
          ),
        ),
        // 后端说明（按平台）
        if (isV4)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                _backendDescription,
                style: TextStyle(
                  color: context.colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        // v4 模型（倍数）选择 + 说明
        if (isV4)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: Anime4KV4ModelManager.getModels().map((m) {
                  final selected = Anime4KV4ModelManager.selectedDef.id == m.id;
                  return ChoiceChip(
                    label: Text("${m.scale}×  ${m.displayName}".tl),
                    selected: selected,
                    onSelected: (_) => _selectModel(m.id),
                  );
                }).toList(),
              ),
            ),
          ),
        if (isV4)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                Anime4KV4ModelManager.selectedDef.description.tl,
                style: TextStyle(
                  color: context.colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        // v4 输出倍数细调（高于原生不支持；4x 模型可 3x/2x 推理后缩小）
        if (isV4)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                "Output Scale".tl,
                style: TextStyle(
                  color: context.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        if (isV4)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: Anime4KV4ModelManager
                    .selectedDef
                    .supportedOutputScales
                    .map(
                      (s) => ChoiceChip(
                        label: Text(
                          s == Anime4KV4ModelManager.selectedDef.scale
                              ? "$s× (${'Native'.tl})"
                              : "$s× (${'Downscaled'.tl})",
                        ),
                        selected:
                            resolveOutputScale(
                              Anime4KV4ModelManager.selectedDef,
                              _rawScale,
                            ) ==
                            s,
                        onSelected: (_) => _setScale(s),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        // v4 输入长边上限：超过上限的页面跳过超分、保持原图（对齐 localManga）
        if (isV4) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                "Pages longer than this keep the original image (upscale skipped)"
                    .tl,
                style: TextStyle(
                  color: context.colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Text(
                      "Max Input Edge".tl,
                      style: TextStyle(
                        color: context.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  for (final edge in const [0, 1200, 1600, 2048, 2560])
                    ChoiceChip(
                      label: Text(edge == 0 ? "Unlimited".tl : "${edge}px".tl),
                      selected: _maxEdge == edge,
                      onSelected: (_) {
                        appdata.settings['anime4KV4MaxEdge'] = edge;
                        appdata.saveData();
                        PaintingBinding.instance.imageCache.clear();
                        ComicImage.clear();
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
        // v1 专用参数（Scale/Push/Grad）：仅 v1 显示
        SliverAnimatedVisibility(
          visible: !isV4,
          child: Column(
            children: [
              _SliderSetting(
                title: "Scale Factor".tl,
                settingsIndex: "anime4KScaleFactor",
                min: 1.0,
                max: 4.0,
                interval: 0.5,
              ),
              _SliderSetting(
                title: "Push Strength".tl,
                settingsIndex: "anime4KPushStrength",
                min: 0.0,
                max: 1.0,
                interval: 0.05,
              ),
              _SliderSetting(
                title: "Gradient Refine Strength".tl,
                settingsIndex: "anime4KPushGradStrength",
                min: 0.0,
                max: 1.0,
                interval: 0.05,
              ),
            ],
          ),
        ),
        // v4 输出倍数细调已在上方"Output Scale"区块
        ListTile(
          title: Text("Clear Anime4K Cache".tl),
          trailing: const Icon(Icons.delete_sweep),
          onTap: () async {
            await Anime4KService.instance.clearCache();
            if (isV4) await Anime4KV4Service.instance.clearCache();
            if (mounted) {
              context.showMessage(message: "Anime4K cache cleared".tl);
            }
          },
        ).toSliver(),
        // ---- v4 模型管理（仅 v4 显示） ----
        if (isV4) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                "Model Management".tl,
                style: TextStyle(
                  color: context.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      Anime4KV4ModelManager.selectedDef.displayName.tl,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isModelDownloaded
                          ? "Model downloaded".tl
                          : "Model not downloaded (~${Anime4KV4ModelManager.selectedDef.sizeHintMB}MB)"
                                .tl,
                      style: TextStyle(
                        color: context.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    if (_status.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _status,
                        style: TextStyle(
                          color: context.colorScheme.primary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (_isDownloading) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: _downloadProgress),
                    ],
                    const SizedBox(height: 12),
                    if (!_usingCustom)
                      Row(
                        children: [
                          if (!_isModelDownloaded)
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _isDownloading
                                    ? null
                                    : _downloadModel,
                                icon: _isDownloading
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.download),
                                label: Text(
                                  _isDownloading
                                      ? "Downloading...".tl
                                      : "Download Model".tl,
                                ),
                              ),
                            ),
                          if (_isModelDownloaded) ...[
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _deleteModel,
                                icon: const Icon(Icons.delete_outline),
                                label: Text("Delete Model".tl),
                              ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
          // 自选本地模型文件
          SliverToBoxAdapter(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Custom Model File".tl,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _usingCustom
                          ? "Using: ${_customModelName ?? 'custom model'}".tl
                          : "Select a local .onnx model to override the built-in one"
                                .tl,
                      style: TextStyle(
                        color: context.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _pickLocalModel,
                            icon: const Icon(Icons.folder_open),
                            label: Text("Select Model File".tl),
                          ),
                        ),
                        if (_usingCustom) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _clearCustomModel,
                              icon: const Icon(Icons.restore),
                              label: Text("Use Built-in".tl),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 镜像 URL 管理
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                "Download Mirrors".tl,
                style: TextStyle(
                  color: context.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          ..._modelUrls.asMap().entries.map(
            (e) => _MirrorUrlTile(
              index: e.key,
              url: e.value,
              onDelete: _removeMirrorUrl,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _addMirrorUrl,
                      icon: const Icon(Icons.add),
                      label: Text("Add Mirror URL".tl),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await Anime4KV4ModelManager.resetModelUrls();
                        await _refreshModelStatus();
                      },
                      icon: const Icon(Icons.restart_alt),
                      label: Text("Reset".tl),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
