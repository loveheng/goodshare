/// 端侧 LLM 模型目录（2026-09-28，设计见 docs/design/on-device-llm.md）。
///
/// 与 `AsrModel` 同构：档位目录 + 必需文件 + 下载 URL 组装。目录条目口径
/// （设计 §3.1）：**官方直下包优先，缺档再评社区包/自编**。
///
/// 已核实现（2026-09-28 官网核实）：
/// - LiteRT-LM 官方 `.litertlm` 目录仅 ~10 个模型，新模型需 litert-torch 自行转换；
/// - 文本通用档定 Qwen2.5-1.5B 8-bit（官方直下，4096 ctx）——**无官方 int4**；
/// - NPU 档（SM8750 / MT6991）官方直下 Gemma3-1B 4bit 专包，按 SoC 分文件（二阶段接入）。
class LlmModel {
  const LlmModel({
    required this.id,
    required this.name,
    required this.desc,
    required this.repo,
    required this.file,
    this.socModel,
  });

  /// 持久化标识（设置/缓存目录用）。
  final String id;

  /// 展示名。
  final String name;

  /// 档位描述（设置页 subtitle）。
  final String desc;

  /// HuggingFace 仓库路径（{base}/resolve/main/{file}）。
  final String repo;

  /// 单文件模型（`.litertlm` 自带 tokenizer 与 chat template，无伴随文件）。
  final String file;

  /// NPU 专包限定的 SoC 型号（`ro.soc.model` 精确匹配，如 'SM8750'）；
  /// null = 通用包（GPU/CPU，全设备可下载）。
  final String? socModel;

  int get sizeBytes => sizeOf(file);

  String urlFor(String base) => '$base/$repo/resolve/main/$file';
}

/// 远端文件大小占位（下载前提示用）。官方直下包按官网数据填写；
/// 下载管理器会以 HEAD/实际响应修正，此处仅影响提示文案。
int sizeOf(String file) => switch (file) {
      'Qwen2.5-1.5B-Instruct_q8_ekv4096.litertlm' => 1597000000, // ~1.5GB 官网档
      'Gemma3-1B-IT_q4_ekv1280_SM8750.litertlm' => 690000000, // ~658MB 官网档
      'Gemma3-1B-IT_q4_ekv1280_MT6991.litertlm' => 1034000000, // ~986MB 官网档
      _ => 0,
    };

/// HuggingFace 基础地址（复用 ASR 的 hf-mirror 口径；换 R2 自托管时只改这里）。
const String llmModelBase = 'https://hf-mirror.com';

/// 模型目录。通用包一条；NPU 专包按 SoC 各一条（二阶段启用，先入目录便于设置页探测）。
const List<LlmModel> llmModels = [
  LlmModel(
    id: 'qwen25-1.5b-q8',
    name: '通用 · Qwen2.5-1.5B',
    desc: '中文原生，摘要/关键词质量优先（约 1.5GB，4096 上下文）',
    repo: 'litert-community/Qwen2.5-1.5B-Instruct',
    file: 'Qwen2.5-1.5B-Instruct_q8_ekv4096.litertlm',
  ),
  LlmModel(
    id: 'gemma3-1b-npu-sm8750',
    name: 'NPU · 骁龙8至尊版',
    desc: 'Gemma3-1B 4bit NPU 专包（约 658MB，仅骁龙 8 Elite 设备可见）',
    repo: 'litert-community/Gemma3-1B-IT',
    file: 'Gemma3-1B-IT_q4_ekv1280_SM8750.litertlm',
    socModel: 'SM8750',
  ),
  LlmModel(
    id: 'gemma3-1b-npu-mt6991',
    name: 'NPU · 天玑9400',
    desc: 'Gemma3-1B 4bit NPU 专包（约 986MB，仅天玑 9400 设备可见）',
    repo: 'litert-community/Gemma3-1B-IT',
    file: 'Gemma3-1B-IT_q4_ekv1280_MT6991.litertlm',
    socModel: 'MT6991',
  ),
];

LlmModel? llmModelById(String? id) {
  if (id == null) return null;
  for (final m in llmModels) {
    if (m.id == id) return m;
  }
  return null;
}
