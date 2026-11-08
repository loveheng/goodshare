library;

/// AI 回写标签的领域校验（数据 owner 侧护栏）。
///
/// goodhub 只提供通用推理与任务管线能力，不为任何单个服务写适配代码；模型
/// 返回整段 markdown 或长句时，宿主的通用分隔符切分会把它变成碎片「标签」。
/// 本仓在 AI 结果回写动作层拦下不合规产出：整批拒绝、不污染条目，原因经
/// 任务 `last_note` 对人与 AI 同时可见（R1/R3）。
///
/// 口径与真机验收 `scripts/e2e/ai-capability-e2e.mjs` 的 `isBadTag` 对齐，
/// 两边各自单一出处——生产代码不依赖测试脚本。
const int kMaxAiTagsPerResult = 12;
const int kMaxAiTagLength = 24;

final RegExp _kStructuralMarks = RegExp(r'[\r\n*#|`>\[\]{}()（）:：。！!?？]');
final RegExp _kWhitespace = RegExp(r'\s');

/// 返回不合规原因清单（空 = 全部合规）。
///
/// 只校验相对 [existing] 的**新增**标签：原有标签由用户手动维护，是权威数据，
/// 不受 AI 产出格式约束；校验也不改变「只增不删」的并集语义（D2）。
List<String> invalidAiTags(List<String> existing, List<String> incoming) {
  final added = <String>[];
  for (final tag in incoming) {
    if (!existing.contains(tag) && !added.contains(tag)) added.add(tag);
  }

  final problems = <String>[];
  if (added.length > kMaxAiTagsPerResult) {
    problems.add('一次新增 ${added.length} 个标签（上限 $kMaxAiTagsPerResult），'
        '疑似整段文本被切碎');
  }
  for (final tag in added) {
    final s = tag.trim();
    final sample = s.length > 30 ? '${s.substring(0, 30)}…' : s;
    if (s.isEmpty) {
      problems.add('空标签');
    } else if (s.length > kMaxAiTagLength) {
      problems.add('「$sample」超过 $kMaxAiTagLength 字');
    } else if (_kStructuralMarks.hasMatch(s)) {
      problems.add('「$sample」含 markdown/句子标记');
    } else if (_kWhitespace.allMatches(s).length > 2) {
      problems.add('「$sample」是句子碎片（空白过多）');
    }
  }
  return problems;
}
