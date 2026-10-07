import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import 'ort_upscale_core.dart';
import 'upscale_models.dart';

/// 常驻 isolate 的 ONNX 超分 worker。
///
/// ONNX 会话（FFI 资源）不能跨 isolate 传递，因此把会话固定在一个长驻 isolate 中，
/// 模型只加载一次（MangaJaNai 等大模型 60MB+，逐图重建会话开销不可接受）。
/// 请求按序执行（同一会话不支持并发 run），进度经消息回传。
class OrtUpscaleWorker {
  Isolate? _isolate;
  SendPort? _sendPort;
  final ReceivePort _receivePort = ReceivePort();
  final Map<int, Completer<Uint8List?>> _pending = {};
  final Map<int, void Function(double)> _progress = {};
  Completer<void>? _ready;
  final Map<int, Completer<void>> _resetWaiters = {};
  String? _loadedPath;
  int _seq = 0;

  OrtUpscaleWorker._();

  static Future<OrtUpscaleWorker> spawn() async {
    final worker = OrtUpscaleWorker._();
    final ready = Completer<SendPort>();
    worker._isolate = await Isolate.spawn(
        _workerMain, worker._receivePort.sendPort);
    // 单监听器：首条消息是 worker 的 SendPort 握手，其余路由到消息处理
    worker._receivePort.listen((message) {
      if (message is Map &&
          message['event'] == 'port' &&
          !ready.isCompleted) {
        ready.complete(message['port'] as SendPort);
        return;
      }
      worker._onMessage(message);
    });
    worker._sendPort = await ready.future
        .timeout(const Duration(seconds: 30));
    return worker;
  }

  /// 当前已加载的模型路径（供调用方判断是否需要 reload）。
  String? get loadedModelPath => _loadedPath;

  /// 确保会话已加载 [def]（路径不同则自动重载）。加载失败抛异常。
  Future<void> ensureLoaded(UpscaleModelDef def, String modelPath) async {
    if (_loadedPath == modelPath && _ready == null) return;
    if (_ready == null) {
      _ready = Completer<void>();
      _sendPort!.send({'cmd': 'load', 'def': def, 'path': modelPath});
    }
    try {
      await _ready!.future.timeout(const Duration(minutes: 5));
    } finally {
      // 成功后清空以便后续请求直接走 loaded 判断；失败同样清空以便重试。
      _ready = null;
    }
  }

  /// 执行一次超分。失败/超时抛异常，由调用方决定回退。
  Future<Uint8List?> run(
    OrtUpscaleRequest request, {
    void Function(double progress)? onProgress,
    Duration timeout = const Duration(minutes: 20),
  }) async {
    if (_sendPort == null) {
      throw StateError('worker not spawned');
    }
    final id = ++_seq;
    final completer = Completer<Uint8List?>();
    _pending[id] = completer;
    if (onProgress != null) {
      _progress[id] = onProgress;
    }
    _sendPort!.send({
      'cmd': 'run',
      'id': id,
      'bytes': request.imageBytes,
      'modelPath': request.modelPath,
      'def': request.model,
      'maxInputEdge': request.maxInputEdge,
      'intensity': request.intensity,
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      _progress.remove(id);
      rethrow;
    } finally {
      _pending.remove(id);
      _progress.remove(id);
    }
  }

  /// 释放会话（切换模型前调用；下次 ensureLoaded 会重新加载）。
  Future<void> reset() async {
    if (_sendPort == null || _loadedPath == null) return;
    final id = ++_seq;
    final completer = Completer<void>();
    _resetWaiters[id] = completer;
    _sendPort!.send({'cmd': 'reset', 'id': id});
    try {
      await completer.future.timeout(const Duration(minutes: 1));
    } finally {
      _resetWaiters.remove(id);
    }
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort.close();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    _loadedPath = null;
  }

  void _onMessage(dynamic message) {
    if (message is! Map) return;
    switch (message['event']) {
      case 'loaded':
        if (message['error'] != null) {
          _loadedPath = null;
          _ready?.completeError(Exception(message['error']));
          _ready = null;
        } else {
          _loadedPath = message['path'] as String?;
          _ready?.complete();
          _ready = null;
        }
        break;
      case 'resetDone':
        _loadedPath = null;
        final waiter = _resetWaiters.remove(message['id']);
        if (waiter != null && !waiter.isCompleted) waiter.complete();
        break;
      case 'progress':
        final callback = _progress[message['id'] as int];
        if (callback != null) {
          callback((message['value'] as num).toDouble());
        }
        break;
      case 'done':
        final completer = _pending.remove(message['id'] as int);
        if (completer != null && !completer.isCompleted) {
          completer.complete(message['bytes'] as Uint8List?);
        }
        _progress.remove(message['id']);
        break;
      case 'error':
        final id = message['id'] as int?;
        final error = message['error']?.toString() ?? 'unknown error';
        if (id != null) {
          final completer = _pending.remove(id);
          if (completer != null && !completer.isCompleted) {
            completer.completeError(Exception(error));
          }
          _progress.remove(id);
        }
        if (_ready != null) {
          // load 阶段失败（无 id 或同批错误）
          if (!_ready!.isCompleted) {
            _ready!.completeError(Exception(error));
          }
          _ready = null;
          _loadedPath = null;
        }
        break;
    }
  }
}

// ================= worker isolate 侧 =================

void _workerMain(SendPort reply) {
  final port = ReceivePort();
  reply.send({'event': 'port', 'port': port.sendPort});

  OrtSession? session;
  String? sessionPath;

  void replyMsg(Map msg) => reply.send(msg);

  port.listen((message) {
    if (message is! Map) return;
    final id = message['id'] as int?;
    try {
      switch (message['cmd']) {
        case 'load':
          final path = message['path'] as String;
          if (session != null && sessionPath == path) {
            replyMsg({'event': 'loaded', 'path': path});
            return;
          }
          session?.release();
          session = null;
          sessionPath = null;
          OrtEnv.instance.init();
          session = createOrtSession(path);
          sessionPath = path;
          replyMsg({'event': 'loaded', 'path': path});
          break;
        case 'run':
          final request = OrtUpscaleRequest(
            imageBytes: message['bytes'] as Uint8List,
            modelPath: message['modelPath'] as String,
            model: message['def'] as UpscaleModelDef,
            maxInputEdge: (message['maxInputEdge'] as num?)?.toInt() ?? 1600,
            intensity: (message['intensity'] as num?)?.toDouble() ?? 1.0,
          );
          // 会话与请求的模型不一致时按需重载（防御性：正常流程 run 前必先 load）
          if (session == null || sessionPath != request.modelPath) {
            session?.release();
            session = null;
            sessionPath = null;
            OrtEnv.instance.init();
            session = createOrtSession(request.modelPath);
            sessionPath = request.modelPath;
          }
          final bytes = runOrtUpscale(
            request,
            session: session,
            onProgress: (p) =>
                replyMsg({'event': 'progress', 'id': id, 'value': p}),
          );
          replyMsg({'event': 'done', 'id': id, 'bytes': bytes});
          break;
        case 'reset':
          session?.release();
          session = null;
          sessionPath = null;
          replyMsg({'event': 'resetDone', 'id': id});
          break;
      }
    } catch (e, s) {
      replyMsg({'event': 'error', 'id': id, 'error': '$e\n$s'});
    }
  });
}
