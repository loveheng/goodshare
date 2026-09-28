import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_model.dart';
import 'subtitle.dart';

/// Sherpa-ONNX 离线转写引擎（2026-09-28）：
/// - 主 isolate：ffmpeg 异步转 16kHz 单声道 WAV（原生进程，不冻 UI），再派给 worker；
///   输入对音频与视频通用（ffmpeg 自动 demux 取首条音频流，视频流被 WAV 容器丢弃）；
/// - worker isolate：sherpa decode 是同步 FFI 调用（期间阻塞所在 isolate 事件循环），
///   必须离开主 isolate；recognizer 在 worker 内按模型缓存，切档才重建；
/// - 通信：worker 启动后先回传自己的任务 SendPort（握手），此后主→worker 发任务、
///   worker→主 发结果，双向各走一条固定通道；
/// - 双通道：`transcribe` 纯文本（无 VAD）；`transcribeToCues` 走 VAD 分段
///   （时间轴来自 SpeechSegment.start / sampleRate，与模型无关——sherpa 官方
///   generate-subtitles.py 对全部模型族统一此路线）；
/// - 失败返回 null，由上层降级（占位复制 / 死信策略归 QueueConsumer）。
class AsrEngine {
  AsrEngine._();
  static final AsrEngine instance = AsrEngine._();

  SendPort? _jobSendPort; // 主→worker 任务通道（worker 握手时回传）
  ReceivePort? _resultPort; // worker→主 结果通道
  final Map<int, Completer<_AsrJobResult>> _pending = {};
  int _nextJobId = 1;

  /// VAD 内置模型的文件路径（随 App assets 分发，主侧解出到私有目录供
  /// worker FFI 读取——isolate 间只传路径不传资源句柄）。null = 未解出。
  static String? _vadModelPath;

  /// 对 [audioPath] 执行离线转写。[modelDir] 为模型缓存目录（主侧解析好传入，
  /// worker 不碰平台通道）。成功返回 trim 后非空文本，失败返回 null。
  Future<String?> transcribe(String audioPath, AsrModel model,
      {required String modelDir}) async {
    final r = await _run(audioPath, model.id, modelDir);
    return r?.text;
  }

  /// 转写并产出字幕 cue（VAD 分段）：音频或视频输入皆可（视频经同一
  /// `_toWav16k` 抽取音轨）。成功返回非空 cue 列表，失败返回 null。
  Future<List<AsrCue>?> transcribeToCues(
      String audioPath, AsrModel model,
      {required String modelDir}) async {
    final vad = await ensureVadModelFile();
    if (vad == null) {
      debugPrint('[AsrEngine] vad model unavailable, cues channel skipped');
      return null;
    }
    final r = await _run(audioPath, model.id, modelDir, vadPath: vad);
    final raw = r?.cues;
    if (raw == null || raw.isEmpty) return null;
    return raw.map(AsrCue.fromJson).toList();
  }

  Future<_AsrJobResult?> _run(String audioPath, String modelId,
      String modelDir,
      {String? vadPath}) async {
    if (!File(audioPath).existsSync()) {
      debugPrint('[AsrEngine] audio not found: $audioPath');
      return null;
    }
    // 1) ffmpeg 转码（async 原生进程，不阻塞 UI）
    final ts = DateTime.now().microsecondsSinceEpoch;
    final wav = File(
        '${Directory.systemTemp.path}/asr_${modelId}_${ts}_${audioPath.hashCode.abs()}.wav')
      ..createSync();
    try {
      if (!await _toWav16k(audioPath, wav.path)) {
        debugPrint('[AsrEngine] ffmpeg convert failed: $audioPath');
        return null;
      }
      // 2) worker 识别（同步 FFI，脱离 UI 线程）
      final result = await _workerTranscribe(wav.path, modelId, modelDir,
              vadPath: vadPath)
          .timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          debugPrint('[AsrEngine] transcribe timeout: $audioPath');
          return _AsrJobResult(0, null, null, 'timeout');
        },
      );
      return result;
    } catch (e) {
      debugPrint('[AsrEngine] transcribe failed: $e');
      return null;
    } finally {
      if (wav.existsSync()) wav.deleteSync();
    }
  }

  /// 解出内置 VAD 模型（assets → 私有目录，幂等）。失败返回 null
  /// （字幕通道随之降级，纯文本转写不受影响）。
  Future<String?> ensureVadModelFile() async {
    final cached = _vadModelPath;
    if (cached != null && File(cached).existsSync()) return cached;
    try {
      final data =
          await rootBundle.load('assets/models/silero_vad_v5.onnx');
      final dir = await getApplicationSupportDirectory();
      final f = File(p.join(dir.path, 'silero_vad_v5.onnx'));
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      _vadModelPath = f.path;
      return f.path;
    } catch (e) {
      debugPrint('[AsrEngine] vad asset extract failed: $e');
      return null;
    }
  }

  /// 释放 worker（app 退出 / 测试 teardown 用）。
  Future<void> dispose() async {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.complete(const _AsrJobResult(0, null, null, 'disposed'));
      }
    }
    _pending.clear();
    _resultPort?.close();
    _resultPort = null;
    _jobSendPort = null;
  }

  Future<_AsrJobResult?> _workerTranscribe(
      String wavPath, String modelId, String modelDir,
      {String? vadPath}) async {
    await _ensureWorker();
    final id = _nextJobId++;
    final completer = Completer<_AsrJobResult>();
    _pending[id] = completer;
    _jobSendPort!.send(_AsrJob(id, wavPath, modelId, modelDir, vadPath));
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
      c.complete(msg); // 成败统一由 result 字段承载（text / cues / error）
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
  const _AsrJob(this.id, this.wavPath, this.modelId, this.modelDir,
      [this.vadPath]);
  final int id;
  final String wavPath;
  final String modelId;
  final String modelDir;

  /// 非空 = 走 VAD 分段通道（返回 cues）；null = 纯文本通道（返回 text）。
  final String? vadPath;
}

class _AsrJobResult {
  const _AsrJobResult(this.id, this.text, this.cues, this.error,
      [this.sampleRate]);
  final int id;
  final String? text;

  /// VAD 通道产物（isolate 间传 JSON-safe List<Map>，主侧还原 AsrCue）。
  final List<Map<String, Object?>>? cues;
  final String? error;

  /// VAD 通道的 wav 采样率（start 索引换算秒用）。
  final int? sampleRate;
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
    List<Map<String, Object?>>? cues;
    int? sampleRate;
    String? error;
    try {
      final rec = cache.get(msg.modelId, msg.modelDir);
      final wave = sherpa.readWave(msg.wavPath);
      if (wave.sampleRate <= 0 || wave.samples.isEmpty) {
        throw StateError('empty/corrupt wav');
      }
      if (msg.vadPath != null) {
        // VAD 分段通道：时间轴来自 SpeechSegment.start（采样点索引），与模型无关
        // （sherpa 官方 generate-subtitles.py 统一路线，参数见 asr-subtitle.md §4）。
        final vad = sherpa.VoiceActivityDetector(
          config: sherpa.VadModelConfig(
            sileroVad: sherpa.SileroVadModelConfig(
              model: msg.vadPath!,
              threshold: 0.2,
              minSilenceDuration: 0.25,
              minSpeechDuration: 0.25,
              maxSpeechDuration: 5,
              windowSize: 512,
            ),
            sampleRate: wave.sampleRate,
          ),
          bufferSizeInSeconds: 100,
        );
        try {
          final list = <Map<String, Object?>>[];
          vad.acceptWaveform(wave.samples);
          vad.flush();
          while (!vad.isEmpty()) {
            final seg = vad.front();
            if (seg.samples.isEmpty) break;
            final stream = rec.createStream();
            try {
              stream.acceptWaveform(
                  samples: seg.samples, sampleRate: wave.sampleRate);
              rec.decode(stream);
              final t = rec.getResult(stream).text.trim();
              if (t.isNotEmpty) {
                list.add(AsrCue(
                  start: seg.start / wave.sampleRate,
                  duration: seg.samples.length / wave.sampleRate,
                  text: t,
                ).toJson());
              }
            } finally {
              stream.free();
            }
            // 必须弹出队首：front() 只取不移除，缺少 pop() 会让 isEmpty() 恒为 false，
            // 变成对同一段反复 decode 的死循环（曾表现为「转写挂死、永不返回」）。
            vad.pop();
          }
          cues = list;
          sampleRate = wave.sampleRate;
        } finally {
          vad.free();
        }
      } else {
        // 纯文本通道（无 VAD，既有行为不变）
        final stream = rec.createStream();
        try {
          stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
          rec.decode(stream);
          text = rec.getResult(stream).text.trim();
        } finally {
          stream.free();
        }
      }
    } catch (e) {
      error = '$e';
    }
    args.resultSendPort
        .send(_AsrJobResult(msg.id, text, cues, error, sampleRate));
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
