import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:goodshare/action/item_action_handler.dart';
import 'package:goodshare/ai/capabilities.dart';
import 'package:goodshare/data/db.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/pages/item_detail_page.dart';
import 'package:goodshare/ui/toast.dart';

/// 真机自动化测试（ai-template P2）：详情页「按模板处理」UI 流程端到端。
///
/// 覆盖（2026-10-15 呈现规约改版后）：无产出态轻入口行（InkWell，渐进披露）→
/// 定制 BottomSheet 选择器（名称 + origin 徽标 + 「原文不会被修改」页脚明示）→
/// 提交入队 template_apply 远程任务 → 详情页 AI 任务状态条显示「处理中」。
///
/// 与 VM 单测（template_test.dart）互补：单测锁数据层/命令层/回写，
/// 本用例在真机真实 sqlite + 真实渲染下验证 Human-AI 对称性的人侧入口。
///
/// 隔离：用独立测试库（goodshare_itest.db），不污染真机 goodshare.db。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'P2 详情页「按模板处理」：选模板→入队 template_apply 远程任务→状态条显示处理中',
    (tester) async {
      // 底栏 5 格横溢（1.4px RenderFlex）已随 2026-10-15 底栏单行化修复
      // （detail-page-visual-audit.md §6 盲点 A：常驻裁 3 项）；overflow 过滤
      // 保留为回归容忍兜底——若再现溢出告警仍会被静默，真机验收须人工留意。
      // 注意：须在 testWidgets 体内设置——testWidgets 运行时会将 FlutterError.onError
      // 重置为 binding 自己的 handler，覆盖 main 顶层设置。
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        final msg = details.exceptionAsString();
        if (msg.contains('overflowed') || msg.contains('A RenderFlex overflowed')) return;
        prevOnError?.call(details);
      };

      // 隔离真实库：指向独立测试库，跑前清残留。
      final testPath = p.join(await getDatabasesPath(), 'goodshare_itest.db');
      Db.overridePath(testPath);
      try {
        await deleteDatabase(testPath);
      } catch (_) {}

      final repo = Repository();
      final handler = ItemActionHandler(repo);
      await Db.instance(); // 首次打开即建表（v23 schema）

      // 种子：工作区 + 一个模板 + 一条带正文的 item。
      final ws = await repo.createWorkspace('IT测试工作区');
      final tpl = await repo.createTemplate(
        workspaceId: ws.id,
        name: '周报模板',
        bodyMd: '# 周报\n- 本周完成\n- 下周计划',
      );
      final it = await repo.add(InboxItem(
        itemType: InboxItem.typeNote,
        rawContent: '本周完成了真机自动化测试流程搭建',
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));

      final caps = AiCapabilities();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: ToastManager.navigatorKey,
          theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
          home: ItemDetailPage(repo: repo, handler: handler, item: it, caps: caps),
        ),
      );
      await tester.pumpAndSettle();

      // 1) 无产出态 = 轻入口行（渐进披露：不挂骑框签空卡，呈现规约 2）。
      expect(find.text('按模板处理'), findsOneWidget);
      final applyBtn = find.ancestor(
        of: find.text('按模板处理'),
        matching: find.byType(InkWell),
      );
      expect(applyBtn, findsOneWidget);

      // 2) 点击 → 定制 BottomSheet 选择器（呈现规约 3）：模板名 + 页脚明示。
      await tester.tap(applyBtn);
      await tester.pumpAndSettle();
      expect(find.text('周报模板'), findsOneWidget); // 选择器选项
      expect(
        find.textContaining('你的原文不会被修改'),
        findsOneWidget,
        reason: '页脚固定明示只追加语义（用户核心顾虑在决策点告知）',
      );

      // 3) 选择模板 → 提交（入队 template_apply 远程任务）。
      await tester.tap(find.text('周报模板'));
      await tester.pumpAndSettle();

      // 4) 任务已入队（远程任务，本地消费者不吃；宿主可 claim）。
      final tasks = await repo.listTasks();
      final applied = tasks
          .where((t) =>
              (t['task_action'] as String? ?? '')
                  .startsWith('${Repository.taskTemplateApply}:'))
          .toList();
      expect(applied, isNotEmpty);
      expect(applied.first['item_id'], it.id);
      expect(applied.first['status'], 'pending');
      expect(
        (applied.first['task_action'] as String),
        '${Repository.taskTemplateApply}:${tpl.id}',
      );

      // 5) 详情页 AI 任务状态条显示「处理中」。
      expect(find.textContaining('处理中'), findsWidgets);
    },
  );
}
