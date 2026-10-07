// 输入体验自测探针（P1b 后输入阻碍审计）：直接驱动纯逻辑引擎 ComposerDoc 模拟
// 典型用户输入序列，把「反直觉 / 易困惑」的实际行为打印出来供人工复核。
//
// 运行：flutter test test/input_self_audit_test.dart
// 本文件只观测【当前实现】的真实输出，不假设「应当如何」；标注 FRICTION 处即
// 用户手感风险点。断言仅锁定当前行为，便于回归时一眼看出模型是否变了。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/share/note_seg.dart' show NoteTextSeg;
import 'package:goodshare/ui/composer_doc.dart' show ComposerDoc;
import 'package:goodshare/ui/span_text_controller.dart'
    show SpanPasteNormalizeFormatter;
import 'package:goodshare/doc/rich_text.dart' show InlineMark;

/// 把一段文本「敲进」当前活跃文本段（视作一次性输入/粘贴，触发随动）。
/// ⚠️ 含 \n 会触发拆段（新段）；构建多行【同一段】内的列表请用 [seedText]。
void type(ComposerDoc doc, String text, {int caret = -1}) {
  final seg = doc.activeText!;
  seg.ctrl.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret < 0 ? text.length : caret),
  );
  doc.applyTextEdit(seg, seg.ctrl.value);
  doc.consumeOutcome();
}

/// 直接把多行文本播种进当前活跃段（inline 随动，不拆段）——用于建模「同一文本
/// 段内的多行列表 / 续行 / 删行」等结构，等价于用户在该段内打字不按回车。
void seedText(ComposerDoc doc, String text) {
  final seg = doc.activeText!;
  seg.ctrl.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  doc.syncSegFromCtrl(seg);
  doc.consumeOutcome();
}

String plain(ComposerDoc doc) => doc.activeText!.spans.plain;
int listRunCount(ComposerDoc doc) => doc.activeText!.spans.listRuns.length;

void main() {
  test('[自测] 列表 / 待办 / 标题输入手感', () {
    // === FRICTION-A：bullet 下回车=新项；多行同项续行 ===
    // 用户期望：在一条 bullet 下回车继续写，第二行自然属于同一项。
    // 实际：enterWithMarker 对非空 bullet 回车插入 "\n- "（新项）；文本真相下
    // 续行靠 parseLine「≥2 空格缩进」判定。
    // 闭环（2026-10-08，按 §7.1 维持 Enter=新项）：多行同项续行已由 F 软换行
    // 覆盖——Shift+Enter（桌面）或工具栏换行钮（移动端 _softBreak）在列表内插
    // "\n  " 续行并入同项（见下方「[修复#3-列表续行]」）。本摩擦归 F 解决，
    // 不再作为开放 bug；下方 expect 仅锁定"回车=新项"语义不被误改。
    final a = ComposerDoc([
      ['t', '']
    ]);
    seedText(a, '- 苹果');
    a.enterOnListLine(a.activeText!);
    a.consumeOutcome();
    print('[A-回车续bullet] plain="${plain(a)}" listRuns=${listRunCount(a)}'
        '（回车得到新 bullet "- "，而非「苹果」的续行）');
    expect(listRunCount(a), 2); // 锁定：回车=新项

    // 知道「2 空格缩进」秘密的人才能造出多行同项：
    final b = ComposerDoc([
      ['t', '']
    ]);
    seedText(b, '- 苹果\n  产地烟台');
    print('[A-2空格续行] listRuns=${listRunCount(b)}'
        '（=1 说明「产地烟台」并入「苹果」项；但正常回车永远到不了这里）');
    expect(listRunCount(b), 1);
    b.disposeAll();

    // === FRICTION-B：有序列表「底层裸同步不越权重排」，结构性删除即时愈合 ===
    // 契约（精确定位，非绝对化"编辑期不重排"）：
    // ① 底层字符流与无门禁同步（seedText→syncSegFromCtrl）不主动重排——防每键
    //    打字 / IME 组合态因重排抖动（正是 B+ 门禁1/2 想守住的边界）；
    // ② 结构性删除（选区删整项 / 删行）在 applyTextEdit 门禁下即时愈合（治 #3）；
    // ③ 落盘（serializeTextTruth / normalizeOrderedNumbers）兜底全篇规整。
    // 本用例只锁 ①：确保裸同步不越权重排，避免把"防抖边界"误删。
    final o = ComposerDoc([
      ['t', '']
    ]);
    seedText(o, '1. a\n2. b\n3. c');
    seedText(o, '1. a\n3. c'); // 删掉中间「2. b」这一行
    print('[B-有序空洞] plain="${plain(o)}"'
        '（裸同步仍留「3. c」：底层不主动重排；结构性删除的即时愈合见下方索引）');
    expect(plain(o).contains('3. c'), isTrue); // 锁定：裸同步不越权重排（非"编辑期永不动"）
    // 交叉索引：结构性删除（选区删整项 / 删行）的即时重排断言见
    //   test/composer_doc_ordered_list_deletion_test.dart
    o.disposeAll();

    // === FRICTION-C（已修：双回车退列防误退）===
    // 预存空 bullet（'- ' 后无正文）首次回车吞键保留列表，需再按一次才退——
    // 防「误清空一行再回车意外掉出列表」。新建空项（上一次回车刚生成）则
    // 维持「再按即退」自然双击离开。
    final e = ComposerDoc([
      ['t', '']
    ]);
    type(e, '- ');
    e.enterOnListLine(e.activeText!);
    e.consumeOutcome();
    print('[C-空项退列] plain="${plain(e)}"'
        '（预存空 bullet 首次回车已防误退：列表保留；再按一次才退出）');
    e.disposeAll();

    // === FRICTION-D（已修 2026-10-08）：粘贴多段（空行）原样保留，段落间距
    // 由编辑器 splitLines 物化为多个段 ===
    // 旧实现把 \n[ \t]*\n+ 折成 \n 吃掉空行；D 专项摘除折叠后，格式化器仅做
    // CRLF 归一，空行 `\n\n` 透传，下游 `_onSegChanged`→splitLines 拆成多段。
    final f = SpanPasteNormalizeFormatter();
    final pasted = f.formatEditUpdate(
      TextEditingValue.empty,
      const TextEditingValue(text: '段落A\n\n段落B'),
    );
    print('[D-粘贴保段] "段落A\\n\\n段落B" → "${pasted.text}"'
        '（空行保留，段落间距不丢；编辑器侧拆为多段）');
    expect(pasted.text, '段落A\n\n段落B'); // 锁定：空行不再被折叠
  });

  test('[自测] 格式化 / 软换行 / 选区手感', () {
    // === FRICTION-E：格式只作用于「之后输入」，选中已有文字套格式无效 ===
    // 用户最自然的动作是「选中一段 → 点 B 加粗」；本模型下这什么都不做，
    // 必须改为「先点 B 激活，再打字」。转盘展开时虽有明示条，但仍有强预期落差。
    final m = ComposerDoc([
      ['t', '']
    ]);
    type(m, 'hello');
    // 模拟「选中 hello 后激活 bold」：选区内无新增文字，applyTextEdit 不会给选区套样式
    final seg = m.activeText!;
    seg.ctrl.value = TextEditingValue(
      text: 'hello',
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    m.applyTextEdit(seg, seg.ctrl.value, activeMarks: const [InlineMark.bold]);
    m.consumeOutcome();
    print('[E-选区不套格式] runs=${seg.spans.runs.length}'
        '（选中「hello」并激活 bold 后 runs 仍为空——已有文字未被加粗）');
    expect(seg.spans.runs.length, 0); // 锁定：选区套格式无效

    // 对比：先激活 bold 再打字，只有新打字部分加粗
    seg.ctrl.value = TextEditingValue(
      text: 'hello world',
      selection: const TextSelection.collapsed(offset: 11),
    );
    m.applyTextEdit(seg, seg.ctrl.value, activeMarks: const [InlineMark.bold]);
    m.consumeOutcome();
    print('[E-对比] 激活 bold 后敲入" world"，bold runs=${seg.spans.runs.length}'
        '（仅新增部分被加粗，符合「先选后打」模型）');
    m.disposeAll();

    // === FRICTION-F：软键盘（移动端）无 Shift，块内软换行不可达 ===
    // Shift+Enter 软换行仅在 _segKeyGate 的硬件 shift 分支触发；移动端软键盘
    // 没有 Shift 键，每次回车都走 splitLines → 新段。结论：移动端用户无法在
    // 单个文本块内做软换行（如地址、诗句），换行即拆成两个独立块。
    // 代码证据：note_composer_editor.dart _segKeyGate 仅 HardwareKeyboard shift。
    print('[F-移动端软换行] 软换行仅硬件 Shift+Enter 触发，'
        '移动端软键盘无 Shift → 无法块内软换行，回车恒拆段。');

    // === FRICTION-G：非焦点行的线级 marker 被隐藏（透明占位）===
    // 文本真相把 `- `/`# `/`- [ ] ` 留在文本里，但 buildSpanTextSpan 对非光标行
    // 隐藏 marker 区间（透明、保宽）。列表项因左侧凹槽仍画 •/勾选框，较直观；
    // 但标题的 `#` 隐藏后用户只能靠字号判断，扫描整篇时「结构感」弱。
    print('[G-marker 隐藏] 非焦点行 marker 透明隐藏（保宽不位移）；'
        '标题已改为次级灰淡显（中困惑 #G 已修），长文扫描结构辨识度提升；'
        '列表项有左侧凹槽仍透明隐藏。');
  });

  test('[验证] 高困惑修复', () {
    // === 修复 #2：选区套格式 ===
    // 选中「hello」后激活 bold，应直接给选区加粗（不再是「只作用于之后输入」）。
    final m = ComposerDoc([
      ['t', '']
    ]);
    seedText(m, 'hello');
    final seg = m.activeText!;
    seg.ctrl.value = const TextEditingValue(
      text: 'hello',
      selection: TextSelection(baseOffset: 0, extentOffset: 5),
    );
    m.applyMarkToSelection(seg, InlineMark.bold);
    m.consumeOutcome();
    print('[修复#2-选区加粗] runs=${seg.spans.runs.length}'
        '（选中文字已被加粗，runs>0 即生效）');
    expect(seg.spans.runs.length, 1);
    expect(seg.spans.runs.first.start, 0);
    expect(seg.spans.runs.first.end, 5);
    // 再切一次 bold → 整段已覆盖则摘掉
    m.applyMarkToSelection(seg, InlineMark.bold);
    m.consumeOutcome();
    print('[修复#2-再切取消] runs=${seg.spans.runs.length}（再次点击取消加粗）');
    expect(seg.spans.runs.length, 0);
    m.disposeAll();

    // === 修复 #1/#3：软换行（列表内续行 / 普通软换行）===
    // 普通块：插软换行不拆段
    final p = ComposerDoc([
      ['t', '']
    ]);
    seedText(p, 'abc');
    p.softNewline(p.activeText!);
    p.consumeOutcome();
    print('[修复#1-普通软换行] segs=${p.segs.length} plain="${plain(p)}"'
        '（普通块插 \\n，仍是单段，未拆块）');
    expect(p.segs.length, 1);
    expect(plain(p), 'abc\n');
    p.disposeAll();

    // 列表项内：插 `\n  ` → 续行并入同一项（listRuns 不增加）
    final l = ComposerDoc([
      ['t', '']
    ]);
    seedText(l, '- 苹果');
    l.softNewline(l.activeText!);
    l.consumeOutcome();
    print('[修复#3-列表续行] plain="${plain(l)}" listRuns=${listRunCount(l)}'
        '（列表内换行插 "\\n  "，续行并入同项，listRuns 仍为 1）');
    expect(plain(l), '- 苹果\n  ');
    expect(listRunCount(l), 1);
    l.disposeAll();
  });
}
