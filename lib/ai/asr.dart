import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../media/wav16k.dart';
import 'asr_model.dart';
import 'subtitle.dart';

/// [AsrEngine.transcribeToCues] 的返回：cue 列表 / 失败原因 / 音频体检数据。
///
/// 三字段正交：`cues` 非空即成功（可能为空列表 = 无语音段）；`error` 非空即
/// 失败；`diag` 与成败无关，恒带回体检数据（R1：跑完却零文本必须有根因）。
class AsrCueResult {
  const AsrCueResult({this.cues, this.error, this.diag});

  /// 成功时的 cue 列表（空列表 = 跑完但无语音段）。
  final List<AsrCue>? cues;

  /// 失败原因；null = 未失败。
  final String? error;

  /// 音频体检数据（时长 / 峰值 / RMS / VAD 分段数），供 note 明说根因。
  final String? diag;
}

/// Sherpa-ONNX 离线转写引擎（2026-09-28）：
/// - 主 isolate：解码输入为 16kHz 单声道 WAV（原生 MediaCodec 解码 + Dart isolate
///   重采样，media-native P2，均不冻 UI；输入对音频与视频通用，视频流被
///   WAV 容器丢弃），再派给 worker；
/// - worker isolate：sherpa decode 是同步 FFI 调用（期间阻塞所在 isolate 事件循环），
///   必须离开主 isolate；recognizer 在 worker 内按模型缓存，切档才重建；
/// - 通信：worker 启动后先回传自己的任务 SendPort（握手），此后主→worker 发任务、
///   worker→主 发结果，双向各走一条固定通道；
/// - 双通道：`transcribe` 纯文本（无 VAD）；`transcribeToCues` 走 VAD 分段
///   （时间轴来自 SpeechSegment.start / sampleRate，与模型无关——sherpa 官方
///   generate-subtitles.py 对全部模型族统一此路线）；
/// - 失败返回 null，由上层降级（占位复制 / 死信策略归 QueueConsumer）；
/// - **音频体检 + 兜底识别**（2026-10-08）：转写「跑完却零产出」曾无法区分
///   「解码产物是静音/噪声」「VAD 不分段」「模型吐标点」三种根因——现在 worker
///   回传时长/峰值/RMS 与 VAD 分段数（[AsrCueResult.diag]），并在「VAD 通道
///   无可用文本但波形有声」时整段直识别兜一次（VAD 参数与音源不匹配的最后一道网）。
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
  /// `_toWav16k` 抽取音轨）。返回 [AsrCueResult]：
  /// - 成功：`cues` 非空、`error` 为 null；
  /// - 失败：`cues` 为 null、`error` 为原因——透传给任务 note（R1：失败必须可
  ///   观测，笼统「模型未产出结果」会掩盖真实原因，如模型文件缺失/解码失败）；
  /// - `diag` 恒带回音频体检数据（时长/峰值/RMS/VAD 分段数），供「跑完但零
  ///   文本」的 note 明说根因（解码产物静音 vs VAD 不分段 vs 模型吐标点）。
  Future<AsrCueResult> transcribeToCues(String audioPath, AsrModel model,
      {required String modelDir}) async {
    final vad = await ensureVadModelFile();
    if (vad == null) {
      debugPrint('[AsrEngine] vad model unavailable, cues channel skipped');
      return const AsrCueResult(
          error: 'VAD 模型解出失败（字幕分段通道不可用）');
    }
    final r = await _run(audioPath, model.id, modelDir, vadPath: vad);
    if (r == null) {
      return const AsrCueResult(error: '音频解码/重采样失败（格式不支持或文件损坏）');
    }
    if (r.error != null) {
      return AsrCueResult(error: '转写引擎报错：${r.error}', diag: r.diag);
    }
    final raw = r.cues;
    if (raw == null || raw.isEmpty) {
      return AsrCueResult(error: '模型未产出结果（${r.diag ?? '无体检数据'}）', diag: r.diag);
    }
    return AsrCueResult(cues: raw.map(AsrCue.fromJson).toList(), diag: r.diag);
  }

  Future<_AsrJobResult?> _run(String audioPath, String modelId,
      String modelDir,
      {String? vadPath}) async {
    // content:// 引用模式条目（不复制原件）：Dart File 无法 stat 跨进程 URI，
    // 解码由原生侧 ContentResolver 数据源承载——放行给原生判断可达性。
    final isUri = audioPath.startsWith('content://') || audioPath.startsWith('file://');
    if (!isUri && !File(audioPath).existsSync()) {
      debugPrint('[AsrEngine] audio not found: $audioPath');
      return null;
    }
    // 1) 解码为 16k 单声道 WAV（原生解码不阻塞 UI；重采样在独立 isolate）
    final ts = DateTime.now().microsecondsSinceEpoch;
    final wav = File(
        '${Directory.systemTemp.path}/asr_${modelId}_${ts}_${audioPath.hashCode.abs()}.wav')
      ..createSync();
    try {
      if (!await _toWav16k(audioPath, wav.path)) {
        debugPrint('[AsrEngine] decode/resample failed: $audioPath');
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
      // 必须带 offset/length 切片：`rootBundle.load` 返回的 ByteData 可能是更大
      // buffer 上的视图，裸 `buffer.asUint8List()` 会把无关字节一起写进去，
      // 产出损坏的 .onnx（VAD 加载失败 → 转写整体不可用）。
      await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
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

  /// 解码为 16kHz 单声道 WAV（原生解码 + isolate 重采样）；成功 true。
  /// 失败多为冷门格式原生解不了（ac3/wma 等）或文件损坏——上层按 R1 给
  /// 「格式不支持」类文案，云端处理为后续规划。
  Future<bool> _toWav16k(String inPath, String outPath) =>
      extractWav16k(inPath, outPath);
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
      [this.sampleRate, this.diag]);
  final int id;
  final String? text;

  /// VAD 通道产物（isolate 间传 JSON-safe List<Map>，主侧还原 AsrCue）。
  final List<Map<String, Object?>>? cues;
  final String? error;

  /// VAD 通道的 wav 采样率（start 索引换算秒用）。
  final int? sampleRate;

  /// 音频体检数据（时长 / 峰值 / RMS / VAD 分段数），成败都回传。
  final String? diag;
}

/// 16k 波形的体检指标（2026-10-08，诊断「跑完却零文本」用）：
/// 峰值/RMS 区分「解码产物是静音或噪声」与「音频本身无语音」。
class _WaveStats {
  const _WaveStats(this.durationSec, this.peak, this.rms);

  final double durationSec;
  final double peak; // 0..1（abs 最大值）
  final double rms;

  @override
  String toString() => '时长 ${durationSec.toStringAsFixed(1)}s、'
      '峰值 ${peak.toStringAsFixed(3)}、RMS ${rms.toStringAsFixed(3)}';
}

_WaveStats _waveStats(int sampleRate, Float32List samples) {
  var peak = 0.0;
  var sum = 0.0;
  for (final s in samples) {
    final a = s.abs();
    if (a > peak) peak = a;
    sum += s * s;
  }
  final n = samples.length;
  return _WaveStats(n / sampleRate, peak, n == 0 ? 0.0 : math.sqrt(sum / n));
}

/// cue 载荷里是否**没有**任何含实义字符的条目（空 / 全标点都算没有）。
bool _noUsableCue(List<Map<String, Object?>> cues) => !cues
    .any((c) => hasSubstantiveText((c['text'] as String?) ?? ''));

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
    String? diag;
    try {
      final rec = cache.get(msg.modelId, msg.modelDir);
      final wave = sherpa.readWave(msg.wavPath);
      if (wave.sampleRate <= 0 || wave.samples.isEmpty) {
        throw StateError('empty/corrupt wav');
      }
      final stats = _waveStats(wave.sampleRate, wave.samples);
      diag = '$stats（采样率 ${wave.sampleRate}Hz）';
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
          var list = <Map<String, Object?>>[];
          // 逐窗喂入（官方 generate-subtitles.py 口径）：一次性 acceptWaveform
          // 整段长音频会顶爆环形缓冲（bufferSizeInSeconds=100），长音频易表现
          // 为「VAD 一段都不吐」；尾部不足一窗的余量交给 flush 收尾。
          const win = 512;
          final n = wave.samples.length;
          for (var i = 0; i + win <= n; i += win) {
            vad.acceptWaveform(Float32List.sublistView(wave.samples, i, i + win));
          }
          vad.flush();
          var segments = 0;
          var withText = 0;
          while (!vad.isEmpty()) {
            final seg = vad.front();
            if (seg.samples.isEmpty) break;
            segments++;
            final stream = rec.createStream();
            try {
              stream.acceptWaveform(
                  samples: seg.samples, sampleRate: wave.sampleRate);
              rec.decode(stream);
              final t = rec.getResult(stream).text.trim();
              if (t.isNotEmpty) {
                withText++;
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
          // 兜底：VAD 通道「零分段」或「分段全吐标点」但波形确实有声（峰值
          // ≥0.01）→ 整段直识别一次再判。VAD 参数（threshold 0.2 / 最短 0.25s）
          // 对安静语音、远场录音、带噪音源会漏段，此时整段喂模型反而能出字。
          // 上限 5 分钟：超长音频整段喂会长时间占住 worker，得不偿失。
          if (_noUsableCue(list) && stats.peak >= 0.01 && stats.durationSec <= 300) {
            final stream = rec.createStream();
            try {
              stream.acceptWaveform(
                  samples: wave.samples, sampleRate: wave.sampleRate);
              rec.decode(stream);
              final t = rec.getResult(stream).text.trim();
              if (t.isNotEmpty) {
                list = [
                  AsrCue(start: 0, duration: stats.durationSec, text: t).toJson()
                ];
              }
            } finally {
              stream.free();
            }
          }
          cues = list;
          sampleRate = wave.sampleRate;
          diag = '$stats、VAD $segments 段（有文本 $withText 段）';
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
        .send(_AsrJobResult(msg.id, text, cues, error, sampleRate, diag));
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

  // modelType 显式给出（2026-10-08）：此前三档都留空靠 sherpa 自行推断，而
  // 官方 Dart 示例对每档都显式赋 modelType；留空时识别器可能建不出对应模型族
  // 的 impl（表现为「模型跑完但零输出」）。取值与 sherpa 官方命名一致
  //（'sense_voice' 带下划线，对应 Python from_sense_voice）。
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
        modelType: 'whisper',
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
        modelType: 'sense_voice',
        numThreads: 2,
      );
    case 'paraformer':
    default:
      modelConfig = sherpa.OfflineModelConfig(
        paraformer: sherpa.OfflineParaformerModelConfig(model: file('model.int8.onnx')),
        tokens: file('tokens.txt'),
        modelType: 'paraformer',
        numThreads: 2,
      );
  }
  return sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: modelConfig));
}
