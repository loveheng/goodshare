import '../models/item.dart';

/// 即时摘要专用 prompt（SSOT：instant-ai-sampling.md §4.1a，施工照录）。
///
/// 两消费者共用单一出处，禁各自复制（MCP 复用而非复制）：
///  - MCP 工具 `ai_summarize_now`（tools.dart，云端 sampling 链路）；
///  - 详情页端侧异步路径（item_detail_page.dart，W6-a `on_device_complete`
///    的 instruction/input 载荷——ai-app-split.md §3.11.2）。
const String kInstantSummarySystem =
    '你是中文摘要引擎。为给定内容输出一段直接可用的摘要正文，不要输出解释、前言或代码块包裹。';

String instantSummaryUserPrompt(InboxItem item, String body) =>
    '请为以下内容生成一段简洁准确的中文摘要（200 字左右，概括核心内容与关键结论）：\n\n'
    '条目标题：${item.humanTitle ?? '（无）'}\n\n正文：\n$body';
