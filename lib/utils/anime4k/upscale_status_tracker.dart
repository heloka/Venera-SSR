import 'dart:async';

import 'package:flutter/foundation.dart';

/// 超分任务状态：等待排队 → 超分中 → 已处理 / 已跳过 / 失败
enum UpscaleJobStatus { queued, processing, done, skipped, failed }

/// 单个超分任务的状态记录（阅读器状态胶囊与任务面板展示用）
class UpscaleJob {
  /// 展示标签（如 "第 3 页"）
  final String label;

  /// 页面所属漫画/章节上下文（便于跨章节时区分，当前仅展示用）
  final String? context;

  UpscaleJobStatus status;

  /// 仅 processing 阶段有意义（0-1）
  double progress;

  final String modelId;

  final DateTime enqueuedAt;

  DateTime? finishedAt;

  String? error;

  UpscaleJob({
    required this.label,
    required this.modelId,
    this.context,
    this.status = UpscaleJobStatus.queued,
    this.progress = 0,
    DateTime? enqueuedAt,
  }) : enqueuedAt = enqueuedAt ?? DateTime.now();
}

/// 超分任务状态追踪器（单例，ChangeNotifier）。
///
/// 服务层在入队/开始/进度/结束时上报；阅读器左下角状态胶囊与任务面板监听本对象。
/// 同一任务 key 的重复上报是幂等的（provider.load 可能被 colorization 预载触发两次）。
/// 已完成任务保留 [doneRetention] 后自动清理，失败任务保留更久便于排障。
class UpscaleStatusTracker extends ChangeNotifier {
  UpscaleStatusTracker._();

  static final UpscaleStatusTracker instance = UpscaleStatusTracker._();

  /// 完成任务的保留时长（胶囊"已处理"提示窗口）
  static const Duration doneRetention = Duration(seconds: 6);

  /// 失败任务的保留时长（面板里留时间查看错误）
  static const Duration failedRetention = Duration(seconds: 60);

  /// 任务记录上限（防极端情况下无界增长）
  static const int maxJobs = 60;

  final Map<String, UpscaleJob> _jobs = {};
  final Map<String, Timer> _clearTimers = {};

  /// 正在处理 + 等待排队的任务数
  int get activeCount => _jobs.values
      .where((j) =>
          j.status == UpscaleJobStatus.queued ||
          j.status == UpscaleJobStatus.processing)
      .length;

  /// 等待排队的任务数
  int get queuedCount => _jobs.values
      .where((j) => j.status == UpscaleJobStatus.queued)
      .length;

  /// 是否仍有任务在处理（胶囊显示转圈的条件）
  bool get isBusy => activeCount > 0;

  /// 面板展示：按入队时间倒序的任务快照
  List<MapEntry<String, UpscaleJob>> get snapshot {
    final entries = _jobs.entries.toList()
      ..sort((a, b) => b.value.enqueuedAt.compareTo(a.value.enqueuedAt));
    return List.unmodifiable(entries);
  }

  /// 任务进入队列（等待排队）。同一 key 已存在时不重复计入。
  void enqueue(String key, String label, String modelId, {String? context}) {
    final existing = _jobs[key];
    if (existing != null && existing.status == UpscaleJobStatus.failed) {
      // 失败后重试同页：重置状态
      existing
        ..status = UpscaleJobStatus.queued
        ..progress = 0
        ..error = null
        ..finishedAt = null;
      _cancelClearTimer(key);
      notifyListeners();
      return;
    }
    if (existing != null) {
      return;
    }
    if (_jobs.length >= maxJobs) {
      _evictOldestFinished();
    }
    _jobs[key] = UpscaleJob(label: label, modelId: modelId, context: context);
    notifyListeners();
  }

  /// 任务开始处理
  void start(String key) {
    final job = _jobs[key];
    if (job == null || job.status == UpscaleJobStatus.processing) {
      return;
    }
    if (job.status == UpscaleJobStatus.done) {
      return;
    }
    job.status = UpscaleJobStatus.processing;
    notifyListeners();
  }

  /// 推理进度（0-1）
  void progress(String key, double value) {
    final job = _jobs[key];
    if (job == null || job.status != UpscaleJobStatus.processing) {
      return;
    }
    job.progress = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  /// 任务完成（成功 / 跳过 / 失败）
  void finish(String key,
      {bool success = true, bool skipped = false, String? error}) {
    final job = _jobs[key];
    if (job == null) {
      return;
    }
    job
      ..status = skipped
          ? UpscaleJobStatus.skipped
          : (success ? UpscaleJobStatus.done : UpscaleJobStatus.failed)
      ..progress = success ? 1.0 : job.progress
      ..error = error
      ..finishedAt = DateTime.now();
    final retention = skipped
        ? doneRetention
        : (success ? doneRetention : failedRetention);
    _clearTimers[key]?.cancel();
    _clearTimers[key] = Timer(retention, () {
      _jobs.remove(key);
      _clearTimers.remove(key);
      notifyListeners();
    });
    notifyListeners();
  }

  /// 面板"清空记录"
  void clear() {
    for (final t in _clearTimers.values) {
      t.cancel();
    }
    _clearTimers.clear();
    _jobs.clear();
    notifyListeners();
  }

  void _cancelClearTimer(String key) {
    _clearTimers.remove(key)?.cancel();
  }

  void _evictOldestFinished() {
    String? oldest;
    DateTime? oldestTime;
    for (final e in _jobs.entries) {
      if (e.value.status == UpscaleJobStatus.done ||
          e.value.status == UpscaleJobStatus.failed) {
        final t = e.value.finishedAt ?? e.value.enqueuedAt;
        if (oldestTime == null || t.isBefore(oldestTime)) {
          oldest = e.key;
          oldestTime = t;
        }
      }
    }
    if (oldest != null) {
      _cancelClearTimer(oldest);
      _jobs.remove(oldest);
    } else {
      // 全部活跃（理论上不会出现）：丢最早入队的一条
      final keys = _jobs.keys.toList();
      if (keys.isNotEmpty) {
        _cancelClearTimer(keys.first);
        _jobs.remove(keys.first);
      }
    }
  }

  @override
  void dispose() {
    for (final t in _clearTimers.values) {
      t.cancel();
    }
    _clearTimers.clear();
    _jobs.clear();
    super.dispose();
  }
}
