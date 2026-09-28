/// Sherpa-ONNX 离线 ASR 三档模型目录（2026-09-28 用户拍板：三档全接、按需下载）。
///
/// 模型源用 hf-mirror 镜像（本机直连 huggingface.co 超时，GitHub Releases 已 404）；
/// 体积取 int8 量化文件（float32 全量体积翻倍，端侧无收益）。
class AsrModel {
  const AsrModel({
    required this.id,
    required this.name,
    required this.desc,
    required this.repo,
    required this.files,
    this.modelType,
  });

  /// 持久化标识（设置/缓存目录用）。
  final String id;

  /// 展示名。
  final String name;

  /// 档位描述（设置页 subtitle）。
  final String desc;

  /// hf-mirror 仓库路径（{base}/resolve/main/{file}）。
  final String repo;

  /// 必需文件：本地文件名 → 远端相对路径（大小用于下载前提示）。
  final Map<String, AsrModelFile> files;

  /// 模型族：paraformer / sensevoice / whisper（决定 OfflineModelConfig 构造）。
  final String? modelType;

  int get totalBytes => files.values.fold(0, (s, f) => s + f.size);

  String urlFor(String file) => '$asrModelBase/$repo/resolve/main/${files[file]!.remote}';
}

class AsrModelFile {
  const AsrModelFile(this.remote, this.size);

  final String remote;

  final int size;
}

/// hf-mirror 基础地址（换自有 CDN 时只改这里；路径为 {base}/{owner}/{repo}/resolve/main/{file}）。
const String asrModelBase = 'https://hf-mirror.com';

/// 三档目录。体积为 int8 实测值（2026-09-28 hf-mirror API 核实）。
const List<AsrModel> asrModels = [
  AsrModel(
    id: 'paraformer-zh',
    name: '基础 · 中文',
    desc: 'Paraformer-zh（2023-03-28），中文识别快而省（约 213MB）',
    repo: 'csukuangfj/sherpa-onnx-paraformer-zh-2023-03-28',
    modelType: 'paraformer',
    files: {
      'model.int8.onnx': AsrModelFile('model.int8.onnx', 223385835),
      'tokens.txt': AsrModelFile('tokens.txt', 75756),
    },
  ),
  AsrModel(
    id: 'sensevoice',
    name: '全能 · 多语种',
    desc: 'SenseVoice small，中/英/日/韩/粤 + 情感事件（约 228MB）',
    repo: 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17',
    modelType: 'sensevoice',
    files: {
      'model.int8.onnx': AsrModelFile('model.int8.onnx', 239233841),
      'tokens.txt': AsrModelFile('tokens.txt', 315894),
    },
  ),
  AsrModel(
    id: 'whisper-small',
    name: '全球 · Whisper',
    desc: 'Whisper small，多语种通用（约 360MB）',
    repo: 'csukuangfj/sherpa-onnx-whisper-small',
    modelType: 'whisper',
    files: {
      'small-encoder.int8.onnx': AsrModelFile('small-encoder.int8.onnx', 112442483),
      'small-decoder.int8.onnx': AsrModelFile('small-decoder.int8.onnx', 262226114),
      'small-tokens.txt': AsrModelFile('small-tokens.txt', 816730),
    },
  ),
];

AsrModel? asrModelById(String? id) {
  if (id == null) return null;
  for (final m in asrModels) {
    if (m.id == id) return m;
  }
  return null;
}
