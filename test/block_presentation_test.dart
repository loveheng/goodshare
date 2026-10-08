import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/ui/theme/block_presentation.dart'
    show BlockKind, blockPresentationOf, lineKindOf;

// 统一排版规约（问题#1 引导层·Step 0）：行类型推断与规约表。
void main() {
  test('行类型推断：标题/列表/引用/待办/正文', () {
    expect(lineKindOf('# 灵感', 3), BlockKind.h1);
    expect(lineKindOf('## 灵感', 4), BlockKind.h2);
    expect(lineKindOf('- 苹果', 4), BlockKind.bullet);
    expect(lineKindOf('> 金句', 3), BlockKind.quote);
    expect(lineKindOf('- [ ] 待办', 6), BlockKind.todo);
    expect(lineKindOf('普通段落', 4), BlockKind.plain);
  });

  test('行类型推断：多行取光标所在行', () {
    const text = '普通段落\n# 标题行\n- 列表项';
    // caret 在第三行（列表项）行内
    expect(lineKindOf(text, text.indexOf('列表项') + 1), BlockKind.bullet);
    // caret 在第二行（'# 标题行' = 单 # → H1）行内
    expect(lineKindOf(text, text.indexOf('标题') + 1), BlockKind.h1);
  });

  test('行类型推断：档位 >2 归并到 H2（编辑器仅落 H1/H2）', () {
    expect(lineKindOf('### 小标题', 4), BlockKind.h2);
  });

  test('规约表：markerPrefix 与正文渲染同源', () {
    expect(blockPresentationOf(BlockKind.h1).markerPrefix, '# ');
    expect(blockPresentationOf(BlockKind.quote).markerPrefix, '> ');
    expect(blockPresentationOf(BlockKind.plain).markerPrefix, '');
    // 缺省回退正文，不抛
    expect(blockPresentationOf(BlockKind.todo).kind, BlockKind.todo);
  });
}
