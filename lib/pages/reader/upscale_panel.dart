part of 'reader.dart';

/// "对比原图"开关（阅读器会话内瞬态状态，不持久化）。
///
/// 打开后图片 provider 会以 `compareOriginal` 变体重新解析（imageCache 中
/// 原图/超分图两种变体共存），因此切换可以在已看过的页面上瞬时完成。
final ValueNotifier<bool> _upscaleShowOriginal = ValueNotifier(false);

/// 打开超分任务面板（左下角状态胶囊入口）：
/// 各页排队/处理/完成状态 + 当前页原图对比开关。
void _showUpscaleJobsPanel(BuildContext context) {
  showSideBar(context, const _UpscaleJobsPanel(), width: 400);
}

void _refreshReaderImages() {
  PaintingBinding.instance.imageCache.clear();
  ComicImage.clear();
}

class _WindowsUpscaleControls extends StatelessWidget {
  const _WindowsUpscaleControls();

  @override
  Widget build(BuildContext context) {
    final reader = context.reader;
    final comicId = reader.cid;
    final sourceKey = reader.type.sourceKey;
    return Material(
      color: context.colorScheme.surface.toOpacity(0.92),
      borderRadius: BorderRadius.circular(22),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<int>(
            valueListenable: RealCuganUpscaler.configChanges,
            builder: (context, _, __) => Switch.adaptive(
              value: RealCuganUpscaler.currentConfig(
                comicId,
                sourceKey,
              ).enabled,
              activeThumbColor: context.colorScheme.primary,
              onChanged: (enabled) async {
                final current = await RealCuganUpscaler.loadConfig(
                  comicId: comicId,
                  sourceKey: sourceKey,
                );
                await RealCuganUpscaler.saveConfig(
                  current.copyWith(enabled: enabled),
                  comicId: comicId,
                  sourceKey: sourceKey,
                );
                _refreshReaderImages();
                if (context.mounted) context.reader.update();
              },
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _upscaleShowOriginal,
            builder: (context, compareOriginal, _) => IconButton(
              tooltip: compareOriginal
                  ? 'Show Upscaled'.tl
                  : 'Compare Original'.tl,
              icon: Icon(compareOriginal ? Icons.auto_awesome : Icons.compare),
              onPressed: () {
                _upscaleShowOriginal.value = !compareOriginal;
                context.reader.update();
              },
            ),
          ),
          IconButton(
            tooltip: 'Upscale Settings'.tl,
            icon: const Icon(Icons.tune),
            onPressed: () => context.to(
              () => const SettingsPage(initialPage: 7),
            ),
          ),
          IconButton(
            tooltip: 'Upscale Tasks'.tl,
            icon: const Icon(Icons.memory),
            onPressed: () => _showUpscaleJobsPanel(context),
          ),
          const _UpscaleStatusPill(),
        ],
      ),
    );
  }
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
          return Column(
            children: [
              // 对比原图：当前视图临时切回原始图片（即时切换，不改设置）
              ValueListenableBuilder<bool>(
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
              const Divider(height: 1),
              Expanded(
                child: jobs.isEmpty
                    ? Center(
                        child: Text(
                          "No upscale tasks yet".tl,
                          style: TextStyle(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(12),
                        itemCount: jobs.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = jobs[index];
                          final job = entry.value;
                          return ListTile(
                            leading: _jobIcon(context, job),
                            title: Text(job.label),
                            subtitle: Text(
                              _jobSubtitle(job),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing:
                                job.status == UpscaleJobStatus.failed &&
                                    RealCuganUpscaler.instance
                                        .hasRetry(entry.key)
                                ? IconButton(
                                    tooltip: 'Retry'.tl,
                                    onPressed: () async {
                                      final success =
                                          await RealCuganUpscaler.instance
                                              .retry(entry.key);
                                      if (success && context.mounted) {
                                        _refreshReaderImages();
                                        context.reader.update();
                                      }
                                    },
                                    icon: const Icon(Icons.refresh),
                                  )
                                : job.error == null
                                ? null
                                : Tooltip(
                                    message: job.error!,
                                    child: const Icon(
                                      Icons.error_outline,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _jobIcon(BuildContext context, UpscaleJob job) {
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
      case UpscaleJobStatus.skipped:
        return Icon(
          Icons.image_not_supported_outlined,
          color: context.colorScheme.onSurfaceVariant,
        );
      case UpscaleJobStatus.failed:
        return const Icon(Icons.error, color: Colors.redAccent);
      case UpscaleJobStatus.cancelled:
        return Icon(
          Icons.cancel_outlined,
          color: context.colorScheme.onSurfaceVariant,
        );
    }
  }

  String _jobSubtitle(UpscaleJob job) {
    final model = job.modelId.startsWith('Real-CUGAN')
        ? job.modelId
        : job.modelId == 'v1'
        ? "v1 (CPU)".tl
        : UpscaleModels.byId(job.modelId).displayName;
    final elapsed = job.elapsed == null
        ? '${DateTime.now().difference(job.enqueuedAt).inSeconds}s'
        : '${job.elapsed!.inMilliseconds}ms';
    final backend = job.backendName == null ? '' : ' · ${job.backendName}';
    final dimensions = job.outputWidth == null || job.outputHeight == null
        ? ''
        : ' · ${job.outputWidth}×${job.outputHeight}';
    switch (job.status) {
      case UpscaleJobStatus.queued:
        return "${'Waiting in queue'.tl} · $model";
      case UpscaleJobStatus.processing:
        final progress = job.progress > 0
            ? ' ${(job.progress * 100).toStringAsFixed(0)}%'
            : '';
        return "${'Upscaling'.tl}$progress · $model$backend";
      case UpscaleJobStatus.done:
        return "${'Processed'.tl} · $model$backend · $elapsed$dimensions";
      case UpscaleJobStatus.skipped:
        return "${'Skipped'.tl} · ${job.error ?? ''}";
      case UpscaleJobStatus.failed:
        return "${'Failed'.tl} · $model${job.error == null ? '' : ' · ${job.error}'}";
      case UpscaleJobStatus.cancelled:
        return "${'Cancelled'.tl} · $model";
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
        final settled = tracker.snapshot
            .where(
              (e) =>
                  (e.value.status == UpscaleJobStatus.done ||
                      e.value.status == UpscaleJobStatus.skipped) &&
                  e.value.finishedAt != null &&
                  DateTime.now().difference(e.value.finishedAt!) <
                      UpscaleStatusTracker.doneRetention,
            )
            .length;
        final failed = tracker.snapshot
            .where((entry) => entry.value.status == UpscaleJobStatus.failed)
            .length;
        final visible = active > 0 || settled > 0 || failed > 0;
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
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
                      ] else if (settled > 0) ...[
                        const Icon(
                          Icons.check_circle,
                          color: Colors.green,
                          size: 15,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "${'Processed'.tl} $settled",
                          style: const TextStyle(fontSize: 12),
                        ),
                      ] else if (failed > 0) ...[
                        const Icon(
                          Icons.error_outline,
                          color: Colors.redAccent,
                          size: 15,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          "Failed".tl + " $failed",
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
