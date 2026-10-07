part of 'reader.dart';

/// "对比原图"开关（阅读器会话内瞬态状态，不持久化）。
///
/// 打开后图片 provider 会以 `compareOriginal` 变体重新解析（imageCache 中
/// 原图/超分图两种变体共存），因此切换可以在已看过的页面上瞬时完成。
final ValueNotifier<bool> _upscaleShowOriginal = ValueNotifier(false);

/// 打开 AI 超分快捷面板（阅读器顶栏 AI 按钮入口）。
///
/// 参考 localManga 的阅读器超分面板：实时开关、模型/倍数/长边调节、
/// 当前页原图对比、任务状态入口。所有变更立即生效。
void _showUpscaleQuickPanel(BuildContext context) {
  showSideBar(
    context,
    const _UpscaleQuickPanel(),
    width: 400,
  );
}

class _UpscaleQuickPanel extends StatefulWidget {
  const _UpscaleQuickPanel();

  @override
  State<_UpscaleQuickPanel> createState() => _UpscaleQuickPanelState();
}

class _UpscaleQuickPanelState extends State<_UpscaleQuickPanel> {
  String get _version => appdata.settings['anime4KVersion'] as String? ?? 'v1';

  int get _maxEdge =>
      (appdata.settings['anime4KV4MaxEdge'] as num?)?.toInt() ?? 1600;

  int get _rawScale =>
      (appdata.settings['anime4KV4Scale'] as num?)?.toInt() ?? 0;

  bool get _enabled => appdata.settings['enableAnime4K'] == true;

  /// 应用变更：清空图片缓存并强制当前页重载（结果缓存让已看过的页面瞬时切换）
  void _applyChange() {
    PaintingBinding.instance.imageCache.clear();
    ComicImage.clear();
    context.reader.update();
  }

  void _setEnabled(bool v) {
    appdata.settings['enableAnime4K'] = v;
    appdata.saveData();
    _applyChange();
    if (mounted) setState(() {});
  }

  void _setVersion(String v) {
    if (_version == v) return;
    appdata.settings['anime4KVersion'] = v;
    appdata.saveData();
    _applyChange();
    if (mounted) setState(() {});
  }

  Future<void> _selectModel(String id) async {
    if (Anime4KV4ModelManager.selectedDef.id == id) return;
    await Anime4KV4Service.instance.setModel(id);
    _applyChange();
    if (mounted) setState(() {});
  }

  void _setScale(int scale) {
    if (_rawScale == scale) return;
    appdata.settings['anime4KV4Scale'] = scale;
    appdata.saveData();
    _applyChange();
    if (mounted) setState(() {});
  }

  void _setMaxEdge(int edge) {
    if (_maxEdge == edge) return;
    appdata.settings['anime4KV4MaxEdge'] = edge;
    appdata.saveData();
    _applyChange();
    if (mounted) setState(() {});
  }

  Widget _sectionTitle(String text) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
        child: Text(
          text.tl,
          style: TextStyle(
            color: context.colorScheme.primary,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _chips(List<Widget> chips) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Wrap(spacing: 8, runSpacing: 4, children: chips),
      ),
    );
  }

  Widget _caption(String text) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: Text(
          text.tl,
          style: TextStyle(
            fontSize: 12,
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final def = Anime4KV4ModelManager.selectedDef;
    final isV4 = _version == 'v4';
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("AI Upscale".tl)),
        // 启用超分
        SliverToBoxAdapter(
          child: SwitchListTile(
            title: Text("Enable Upscaling".tl),
            value: _enabled,
            onChanged: _setEnabled,
          ),
        ),
        // 对比原图
        SliverToBoxAdapter(
          child: ValueListenableBuilder<bool>(
            valueListenable: _upscaleShowOriginal,
            builder: (context, value, _) => SwitchListTile(
              title: Text("Compare Original".tl),
              subtitle: Text(
                "Show original image of current view for comparison".tl,
                style: TextStyle(
                  fontSize: 12,
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
              value: value,
              onChanged: (v) {
                _upscaleShowOriginal.value = v;
                context.reader.update();
              },
            ),
          ),
        ),
        _sectionTitle("Engine".tl),
        _chips([
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
        ]),
        if (isV4) ...[
          _sectionTitle("Model".tl),
          _chips(Anime4KV4ModelManager.getModels()
              .map((m) => ChoiceChip(
                    label: Text("${m.scale}× ${m.displayName}".tl),
                    selected: def.id == m.id,
                    onSelected: (_) => _selectModel(m.id),
                  ))
              .toList()),
          _caption(def.description),
          _sectionTitle("Output Scale".tl),
          _chips(def.supportedOutputScales
              .map((s) => ChoiceChip(
                    label: Text(s == def.scale
                        ? "$s× (${'Native'.tl})"
                        : "$s× (${'Downscaled'.tl})"),
                    selected: resolveOutputScale(def, _rawScale) == s,
                    onSelected: (_) => _setScale(s),
                  ))
              .toList()),
          _sectionTitle("Max Input Edge".tl),
          _chips(const [0, 1200, 1600, 2048, 2560]
              .map((e) => ChoiceChip(
                    label: Text(e == 0 ? "Unlimited".tl : "${e}px".tl),
                    selected: _maxEdge == e,
                    onSelected: (_) => _setMaxEdge(e),
                  ))
              .toList()),
        ],
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: OutlinedButton.icon(
              onPressed: () => _showUpscaleJobsPanel(context),
              icon: const Icon(Icons.fact_check_outlined),
              label: Text("Upscale Tasks".tl),
            ),
          ),
        ),
        _caption(
            "Changes apply immediately; previously viewed pages switch instantly from cache"),
      ],
    );
  }
}

/// 打开超分任务面板（各页排队/处理/完成状态）
void _showUpscaleJobsPanel(BuildContext context) {
  showSideBar(
    context,
    const _UpscaleJobsPanel(),
    width: 400,
  );
}

class _UpscaleJobsPanel extends StatelessWidget {
  const _UpscaleJobsPanel();

  @override
  Widget build(BuildContext context) {
    final tracker = UpscaleStatusTracker.instance;
    return Scaffold(
      appBar: Appbar(
        title: Text("Upscale Tasks".tl),
        actions: [
          IconButton(
            icon: const Icon(Icons.clear_all),
            tooltip: "Clear".tl,
            onPressed: () => tracker.clear(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: tracker,
        builder: (context, _) {
          final jobs = tracker.snapshot;
          if (jobs.isEmpty) {
            return Center(
              child: Text(
                "No upscale tasks yet".tl,
                style: TextStyle(color: context.colorScheme.onSurfaceVariant),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: jobs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = jobs[index];
              final job = entry.value;
              return ListTile(
                leading: _jobIcon(job),
                title: Text(job.label),
                subtitle: Text(_jobSubtitle(job)),
                trailing: job.error == null
                    ? null
                    : Tooltip(
                        message: job.error!,
                        child:
                            const Icon(Icons.error_outline, color: Colors.redAccent),
                      ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _jobIcon(UpscaleJob job) {
    switch (job.status) {
      case UpscaleJobStatus.queued:
        return const Icon(Icons.hourglass_top, color: Colors.amber);
      case UpscaleJobStatus.processing:
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        );
      case UpscaleJobStatus.done:
        return const Icon(Icons.check_circle, color: Colors.green);
      case UpscaleJobStatus.failed:
        return const Icon(Icons.error, color: Colors.redAccent);
    }
  }

  String _jobSubtitle(UpscaleJob job) {
    final model = job.modelId == 'v1'
        ? "v1 (CPU)".tl
        : UpscaleModels.byId(job.modelId).displayName;
    final elapsed = DateTime.now().difference(job.enqueuedAt).inSeconds;
    switch (job.status) {
      case UpscaleJobStatus.queued:
        return "${'Waiting in queue'.tl} · $model";
      case UpscaleJobStatus.processing:
        return "${'Upscaling'.tl} ${(job.progress * 100).toStringAsFixed(0)}% · $model";
      case UpscaleJobStatus.done:
        return "${'Processed'.tl} · $model · ${elapsed}s";
      case UpscaleJobStatus.failed:
        return "${'Failed'.tl} · $model";
    }
  }
}

/// 阅读器左下角的超分状态胶囊：
/// 有任务时显示"超分中 n（排队 m）"，全部完成后的短暂窗口显示"已处理 n"。
/// 点击打开任务面板查看每个页面的状态与进度。
class _UpscaleStatusPill extends StatelessWidget {
  const _UpscaleStatusPill();

  @override
  Widget build(BuildContext context) {
    final tracker = UpscaleStatusTracker.instance;
    return ListenableBuilder(
      listenable: tracker,
      builder: (context, _) {
        final active = tracker.activeCount;
        final processing = active - tracker.queuedCount;
        final doneRecently = tracker.snapshot
            .where((e) =>
                e.value.status == UpscaleJobStatus.done &&
                e.value.finishedAt != null &&
                DateTime.now().difference(e.value.finishedAt!) <
                    UpscaleStatusTracker.doneRetention)
            .length;
        final visible = active > 0 || doneRecently > 0;
        return AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 300),
          child: IgnorePointer(
            ignoring: !visible,
            child: Material(
              color: context.colorScheme.surface.toOpacity(0.85),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => _showUpscaleJobsPanel(context),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (active > 0) ...[
                        const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "Upscaling".tl +
                              (processing > 0 ? " $processing" : "") +
                              (tracker.queuedCount > 0
                                  ? " + ${'Queued'.tl} ${tracker.queuedCount}"
                                  : ""),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ] else if (doneRecently > 0) ...[
                        const Icon(Icons.check_circle,
                            color: Colors.green, size: 15),
                        const SizedBox(width: 6),
                        Text(
                          "${'Processed'.tl} $doneRecently",
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
