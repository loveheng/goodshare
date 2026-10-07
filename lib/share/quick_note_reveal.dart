import 'quick_note_line_shape.dart';

/// S1 显隐机制（note-editor-source-of-truth.md §3/§4.4 契约5）：
/// **纯谓词 + 有界 latch，两者分离**——谓词 paint 时求值禁缓存；冻结 latch
/// 有状态且唯一归 L1（编辑器），L2/渲染层对 latch 无感知。
///
/// ⚠️ S1 阶段 buffer 尚无标记（S3 才切文本真相），本模块先行落地机制 +
/// 单测钉住 §3.3 全场景表；行为激活点 = S3（[kNoteMarkerReveal] 旗标）。

/// S3 切换旗标：**已翻转（2026-10-07，唯一不可逆点 §6）**——buffer 即含线级
/// 标记的文本，输入端坐标随动退役（convert/extend/adjust* 家族无对象），
/// 行级身份走 deriveLineRuns 派生视图，显隐判据激活。翻转前门禁：S0–S2
/// 全量测试零回归 + 机制单测就位（已达成）；翻转后真机 dogfood 验收 §7。
const bool kNoteMarkerReveal = true;

/// 冻结 latch（§3.2 稳定态结算）：连续手势期间显隐沿用**进入前状态**，
/// 抬手/静止后才按谓词重新结算。有界：只有两个可变字段，手势结束即复位，
/// 不派生任何文本态（契约 1 不受侵蚀）。
class RevealLatch {
  bool _frozen = false;
  bool _held = false;

  /// 手势开始（拖选/长按退格/IME 组合）：冻结，显隐沿用 [_held]。
  void freeze() => _frozen = true;

  /// 稳定态结算（抬手/静止）：按谓词最新值落定并解冻。**只在稳定态调用**。
  bool settle(bool predicateValue) {
    _frozen = false;
    _held = predicateValue;
    return _held;
  }

  bool get frozen => _frozen;

  /// 冻结期间沿用的显隐值（= 进入手势前的结算结果）。
  bool get heldValue => _held;
}

/// §3.1 判据（纯谓词，单行口径）：
///
/// ```
/// reveal = 光标在该行内
///        ∧ (标记区之后无正文 ∨ 光标 ≤ 标记区末端)
///        ∧ 非冻结
/// ```
///
/// [lineLocalCaret] 为**行内偏移**（0 = 行首，≤ 行长）。纯文本行无标记可显，
/// 恒 false（无变化即无闪烁）。空列表项（`- ` 后无正文）恒显——防「看不见、
/// 点不到、删不掉」陷阱。
bool revealLine({
  required LineShape shape,
  required int lineLength,
  required int lineLocalCaret,
  required bool frozen,
}) {
  if (frozen) return false; // 冻结分支实际取值走 latch.heldValue（见 revealAt）
  if (shape.isPlain) return false;
  if (lineLocalCaret < 0 || lineLocalCaret > lineLength) return false;
  final bodyEmpty = shape.bodyStart >= lineLength;
  return bodyEmpty || lineLocalCaret <= shape.markerEnd;
}

/// 全文本口径判据：定位 [caret] 所在行 → `parseLine` → [revealLine]。
/// 冻结时返回 [heldValue]（§3.2「沿用进入前状态」），谓词不求值。
///
/// 纯函数（latch 值由调用方传入）：同一 `(文本, 光标, 冻结态)` 两次求值一致。
bool revealAt(
  String text,
  int caret, {
  required bool frozen,
  required bool heldValue,
}) {
  if (frozen) return heldValue;
  if (caret < 0 || caret > text.length) return false;
  var start = 0;
  for (var i = 0; i <= text.length; i++) {
    if (i == text.length || text.codeUnitAt(i) == 0x0A) {
      // 行区间 [start, i)
      if (caret >= start && caret <= i) {
        final line = text.substring(start, i);
        final shape = parseLine(line);
        return revealLine(
          shape: shape,
          lineLength: line.length,
          lineLocalCaret: caret - start,
          frozen: false,
        );
      }
      start = i + 1;
    }
  }
  return false;
}
