import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_model.dart';

/// Sherpa-ONNX 离线转写引擎（2026-09-28）：
/// - 主 isolate：ffmpeg 异步转 16kHz 单声道 WAV（原生进程，不冻 UI），再派给 worker；
/// - worker isolate：sherpa decode 是同步 FFI 调用（期间阻塞所在 isolate 事件循环），
///   必须离开主 isolate；recognizer 在 worker 内按模型缓存，切档才重建；
/// - 通信：worker 启动后先回传自己的任务 SendPort（握手），此后主→worker 发任务、
///   worker→主 发结果，双向各走一条固定通道；
/// - 失败返回 null，由上层降级（占位复制 / 死信策略归 QueueConsumer）。
class AsrEngine {
  AsrEngine._();
  static final AsrEngine instance = AsrEngine._();

  SendPort? _jobSendPort; // 主→worker 任务通道（worker 握手时回传）
  ReceivePort? _resultPort; // worker→主 结果通道
  final Map<int, Completer<String?>> _pending = {};
  int _nextJobId = 1;

  /// 对 [audioPath] 执行离线转写。[modelDir] 为模型缓存目录（主侧解析好传入，
  /// worker 不碰平台通道）。成功返回 trim 后非空文本，失败返回 null。
  Future<String?> transcribe(String audioPath, AsrModel model,
      {required String modelDir}) async {
    if (!File(audioPath).existsSync()) {
      debugPrint('[AsrEngine] audio not found: $audioPath');
      return null;
    }
    // 1) ffmpeg 转码（async 原生进程，不阻塞 UI）
    final ts = DateTime.now().microsecondsSinceEpoch;
    final wav = File(
        '${Directory.systemTemp.path}/asr_${model.id}_${ts}_${audioPath.hashCode.abs()}.wav')
      ..createSync();
    try {
      if (!await _toWav16k(audioPath, wav.path)) {
        debugPrint('[AsrEngine] ffmpeg convert failed: $audioPath');
        return null;
      }
      // 2) worker 识别（同步 FFI，脱离 UI 线程）
      final text = await _workerTranscribe(wav.path, model.id, modelDir)
          .timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          debugPrint('[AsrEngine] transcribe timeout: $audioPath');
          return null;
        },
      );
      if (text == null || text.isEmpty) return null;
      return text;
    } catch (e) {
      debugPrint('[AsrEngine] transcribe failed: $e');
      return null;
    } finally {
      if (wav.existsSync()) wav.deleteSync();
    }
  }

  /// 释放 worker（app 退出 / 测试 teardown 用）。
  Future<void> dispose() async {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
    _resultPort?.close();
    _resultPort = null;
    _jobSendPort = null;
  }

  Future<String?> _workerTranscribe(
      String wavPath, String modelId, String modelDir) async {
    await _ensureWorker();
    final id = _nextJobId++;
    final completer = Completer<String?>();
    _pending[id] = completer;
    _jobSendPort!.send(_AsrJob(id, wavPath, modelId, modelDir));
    return completer.future;
  }

  Future<void> _ensureWorker() async {
    final existing = _jobSendPort;
    if (existing != null) return;

    final rp = ReceivePort();
    final ready = Completer<SendPort>();
    rp.listen((dynamic msg) {
      if (msg is SendPort && !ready.isCompleted) {
        ready.complete(msg); // 握手：worker 的任务入口
        return;
      }
      if (msg is! _AsrJobResult) return;
      final c = _pending.remove(msg.id);
      if (c == null || c.isCompleted) return;
      if (msg.error != null) {
        debugPrint('[AsrEngine] worker: ${msg.error}');
        c.complete(null);
      } else {
        c.complete(msg.text);
      }
    });
    try {
      await Isolate.spawn(_asrWorkerEntry, _AsrWorkerArgs(rp.sendPort));
    } catch (e) {
      rp.close();
      throw StateError('ASR worker spawn failed: $e');
    }
    try {
      _jobSendPort = await ready.future.timeout(const Duration(seconds: 10));
    } catch (e) {
      rp.close();
      throw StateError('ASR worker handshake failed: $e');
    }
    _resultPort = rp;
  }

  /// ffmpeg 转 16kHz 单声道 WAV；成功 true。
  Future<bool> _toWav16k(String inPath, String outPath) async {
    final cmd = '-hide_banner -loglevel error -y -i "$inPath" '
        '-ar 16000 -ac 1 -c:a pcm_s16le "$outPath"';
    final session = await FFmpegKit.execute(cmd);
    final rc = await session.getReturnCode();
    return ReturnCode.isSuccess(rc);
  }
}

// ---------------------------------------------------------------------------
// worker isolate 侧
// ---------------------------------------------------------------------------

class _AsrJob {
  const _AsrJob(this.id, this.wavPath, this.modelId, this.modelDir);
  final int id;
  final String wavPath;
  final String modelId;
  final String modelDir;
}

class _AsrJobResult {
  const _AsrJobResult(this.id, this.text, this.error);
  final int id;
  final String? text;
  final String? error;
}

class _AsrWorkerArgs {
  const _AsrWorkerArgs(this.resultSendPort);
  final SendPort resultSendPort;
}

/// worker 入口：每个 isolate 需单独 init FFI bindings（sherpa 要求）。
/// 先回传任务入口（握手），再开始消费任务。
void _asrWorkerEntry(_AsrWorkerArgs args) {
  sherpa.initBindings();
  final cache = _RecognizerCache();
  final jobs = ReceivePort();
  args.resultSendPort.send(jobs.sendPort); // 握手
  jobs.listen((dynamic msg) {
    if (msg is! _AsrJob) return;
    String? text;
    String? error;
    try {
      final rec = cache.get(msg.modelId, msg.modelDir);
      final wave = sherpa.readWave(msg.wavPath);
      if (wave.sampleRate <= 0 || wave.samples.isEmpty) {
        throw StateError('empty/corrupt wav');
      }
      final stream = rec.createStream();
      try {
        stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
        rec.decode(stream);
        text = rec.getResult(stream).text.trim();
      } finally {
        stream.free();
      }
    } catch (e) {
      error = '$e';
    }
    args.resultSendPort.send(_AsrJobResult(msg.id, text, error));
  });
}

/// recognizer 缓存：模型/目录一致则复用，否则释放重建。
/// 用类字段而非闭包捕获局部变量（闭包内被捕获变量不做类型提升）。
class _RecognizerCache {
  sherpa.OfflineRecognizer? _rec;
  String? _modelId;
  String? _modelDir;

  sherpa.OfflineRecognizer get(String modelId, String dir) {
    if (_rec == null || _modelId != modelId || _modelDir != dir) {
      _rec?.free();
      _rec = _buildRecognizer(modelId, dir);
      _modelId = modelId;
      _modelDir = dir;
    }
    return _rec!;
  }
}

/// 按模型族构造 recognizer（文件布局与 asr_model.dart 目录一致）。
sherpa.OfflineRecognizer _buildRecognizer(String modelId, String dir) {
  final model = asrModelById(modelId);
  if (model == null) throw StateError('unknown asr model: $modelId');
  String file(String name) => p.join(dir, name);

  final sherpa.OfflineModelConfig modelConfig;
  switch (model.modelType) {
    case 'whisper':
      modelConfig = sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: file('small-encoder.int8.onnx'),
          decoder: file('small-decoder.int8.onnx'),
          language: 'auto',
          task: 'transcribe',
        ),
        tokens: file('small-tokens.txt'),
        numThreads: 2,
      );
    case 'sensevoice':
      modelConfig = sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: file('model.int8.onnx'),
          language: 'auto',
          useInverseTextNormalization: true,
        ),
        tokens: file('tokens.txt'),
        numThreads: 2,
      );
    case 'paraformer':
    default:
      modelConfig = sherpa.OfflineModelConfig(
        paraformer: sherpa.OfflineParaformerModelConfig(model: file('model.int8.onnx')),
        tokens: file('tokens.txt'),
        numThreads: 2,
      );
  }
  return sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: modelConfig));
}
