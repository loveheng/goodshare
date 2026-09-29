import 'dart:io';

import '../models/item.dart';

/// 附件引用状态与可达性（content-pipeline.md §7）。
///
/// 引用模式下（app 不复制原件）原件可能被删除或授权失效，UI 必须能判定并**明示**——
/// 不能只显示一个 broken_image 图标了事（R1：降级/失效必须被用户感知）。
///
/// 状态机：`ref`（引用未复制）→ 用户点导入 → `owned`（已持有副本）；
/// 任何状态下原件不可达 → `lost`。
class Attach {
  const Attach._();

  /// 依据「当前状态 + 是否可达」解析最终状态（纯函数，可单测）。
  ///
  /// - `lost` 且又变可达（如原件恢复）→ 回到 `owned`（曾持有副本的语义）
  /// - 其余状态不可达 → `lost`
  static String resolveState(String state, bool reachable) {
    if (!reachable) return InboxItem.attachLost;
    if (state == InboxItem.attachLost) return InboxItem.attachOwned;
    return state;
  }

  /// 引用中（未复制）——app 不持有，原件失效即不可访问。
  static bool isRef(String state) => state == InboxItem.attachRef;

  /// 附件是否可读。
  ///
  /// **异步**：这是文件 stat IO，同步调用会阻塞主线程（列表滚动路径上尤其致命，
  /// 项目已有同类教训：图片「有标注」角标曾因 stat IO 需异步缓存）。
  /// 无附件（纯文本条目）视为可达——它本来就没有外部依赖。
  static Future<bool> reachable(InboxItem item) async {
    final path = item.rawFilePath;
    if (path == null || path.isEmpty) return true;
    try {
      return await File(path).exists();
    } catch (_) {
      // 权限异常 / 路径非法：按不可达处理，不抛给 UI
      return false;
    }
  }

  /// 失效态文案（给 UI 直接展示；不自行编造兜底文案，只陈述事实）。
  static String? statusText(String state) => switch (state) {
        InboxItem.attachRef =>
          '临时引用：原件删除或授权失效后将无法打开',
        InboxItem.attachLost =>
          '原件已不可访问（可能已删除或授权过期）',
        _ => null,
      };
}
