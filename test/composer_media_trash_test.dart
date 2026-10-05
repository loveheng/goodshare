import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ui/note_composer_editor.dart';
import 'package:goodshare/ui/goodshare_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 媒体移除回收站（延迟删除，2026-10-04 拍板）回归：移除入桶、撤销还原、
/// 重做再入桶、编辑器销毁清桶。
void main() {
  late Directory tmp;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('composer_media_trash_test');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  File makeImage(String name) =>
      File('${tmp.path}/$name')..writeAsBytesSync(<int>[0, 1, 2, 3]);

  List<String> trashedFiles() {
    final root = Directory('${tmp.path}/.trash_media');
    if (!root.existsSync()) return const [];
    return [
      for (final e in root.listSync(recursive: true))
        if (e is File) e.path,
    ];
  }

  Future<NoteComposerEditorState> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final img = makeImage('p.jpg');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 600,
          child: NoteComposerEditor(
            initialRows: [
              ['t', '前'],
              ['i', img.path],
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return tester.state(find.byType(NoteComposerEditor))
        as NoteComposerEditorState;
  }

  /// 滑动确认删除媒体卡（同向快甩=确认）。
  Future<void> swipeRemove(WidgetTester tester) async {
    await tester.fling(
      find.byType(GoodshareImage),
      const Offset(-300, 0),
      3000,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('移除媒体：文件入回收站而非删除', (tester) async {
    final state = await pump(tester);
    final imgPath = (state.segs[1] as NoteMediaSeg).file.path;

    await swipeRemove(tester);
    expect(state.segs.length, 1, reason: '媒体段已移除');
    expect(File(imgPath).existsSync(), isFalse, reason: '原位文件已挪走');
    expect(trashedFiles(), hasLength(1), reason: '文件在回收站桶内');
  });

  testWidgets('撤销移除：文件从回收站还原原位', (tester) async {
    final state = await pump(tester);
    final imgPath = (state.segs[1] as NoteMediaSeg).file.path;

    await swipeRemove(tester);
    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pumpAndSettle();

    expect(state.segs.length, 3, reason: '媒体段恢复（媒体后恒有尾随文本段）');
    expect(File(imgPath).existsSync(), isTrue, reason: '文件还原原位');
    expect(trashedFiles(), isEmpty, reason: '回收站账清空');
    expect((state.segs[1] as NoteMediaSeg).file.existsSync(), isTrue,
        reason: '卡片预览恢复');
  });

  testWidgets('重做移除：文件再次入回收站（与撤销对称）', (tester) async {
    final state = await pump(tester);
    final imgPath = (state.segs[1] as NoteMediaSeg).file.path;

    await swipeRemove(tester);
    await tester.tap(find.byIcon(Icons.undo_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.redo_outlined));
    await tester.pumpAndSettle();

    expect(state.segs.length, 1);
    expect(File(imgPath).existsSync(), isFalse, reason: '重做=再移除，文件回桶');
    expect(trashedFiles(), hasLength(1));
  });

  testWidgets('编辑器销毁：回收站清空（延迟删除收敛为删除）', (tester) async {
    final state = await pump(tester);
    final imgPath = (state.segs[1] as NoteMediaSeg).file.path;

    await swipeRemove(tester);
    expect(trashedFiles(), hasLength(1));

    // 模拟用户退出编辑页：编辑器销毁 → 桶清空
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pumpAndSettle();

    expect(File(imgPath).existsSync(), isFalse);
    expect(trashedFiles(), isEmpty, reason: 'dispose 清桶，文件彻底删除');
  });
}
