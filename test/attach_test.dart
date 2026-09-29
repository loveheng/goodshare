import 'package:flutter_test/flutter_test.dart';

import 'package:goodshare/doc/attach.dart';
import 'package:goodshare/models/item.dart';

void main() {
  group('引用状态解析', () {
    test('引用中且可达 → 保持 ref', () {
      expect(Attach.resolveState(InboxItem.attachRef, true), InboxItem.attachRef);
    });

    test('引用中但不可达 → lost', () {
      expect(Attach.resolveState(InboxItem.attachRef, false), InboxItem.attachLost);
    });

    test('已持有但文件丢失 → lost（副本也可能被清）', () {
      expect(Attach.resolveState(InboxItem.attachOwned, false), InboxItem.attachLost);
    });

    test('lost 后又可达 → 回到 owned', () {
      expect(Attach.resolveState(InboxItem.attachLost, true), InboxItem.attachOwned);
    });
  });

  group('状态判定与文案', () {
    test('仅 ref 视为引用中', () {
      expect(Attach.isRef(InboxItem.attachRef), isTrue);
      expect(Attach.isRef(InboxItem.attachOwned), isFalse);
      expect(Attach.isRef(InboxItem.attachLost), isFalse);
    });

    test('引用与失效都有明示文案，正常态不占位', () {
      expect(Attach.statusText(InboxItem.attachRef), isNotNull);
      expect(Attach.statusText(InboxItem.attachLost), contains('不可访问'));
      expect(Attach.statusText(InboxItem.attachOwned), isNull);
    });
  });

  group('可达性', () {
    test('纯文本条目（无附件）视为可达', () async {
      final item = InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: 'x',
        createdAt: 0,
      );
      expect(await Attach.reachable(item), isTrue);
    });

    test('文件路径不存在 → 不可达，且不抛异常', () async {
      final item = InboxItem(
        itemType: InboxItem.typeImage,
        rawFilePath: '/nonexistent/path/to/file.jpg',
        createdAt: 0,
      );
      expect(await Attach.reachable(item), isFalse);
    });
  });
}
