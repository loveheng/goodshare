import 'package:flutter/material.dart';

import 'action/item_action_handler.dart';
import 'ai/capabilities.dart';
import 'ai/ocr_reconstructor.dart';
import 'ai/queue_consumer.dart';
import 'ai/reconstructor.dart';
import 'data/db.dart';
import 'data/repository.dart';
import 'pages/home_shell.dart';
import 'service/mcp_controller.dart';
import 'share/share_intake.dart';
import 'share/text_collector.dart';
import 'update/remote_config_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = Repository();
  // 预热数据库，避免首页先闪空态；顺带物理清理超过 30 天的已删条目
  await Db.instance();
  await repo.purgeDeleted();
  final collector = TextCollector(repo);
  await collector.load();
  final caps = AiCapabilities();
  await caps.load();
  // 本机能力检测：首次执行后持久化，此后不再检测
  await caps.ensureDetected();
  final handler = ItemActionHandler(repo);
  final mcp = McpController(repo: repo);
  await mcp.load();
  await RemoteConfigStore.instance.load();
  await ShareIntake(repo, collector).init();
  // AI 队列消费者：v1 = 图片 ML Kit OCR（受设置开关门控）+ 链接离线抓取 + 其余占位复制
  QueueConsumer(
    repo,
    ReconstructorRegistry([
      OcrReconstructor(
        isOcrEnabled: () => caps.ocrEnabled,
        isUrlFetchEnabled: () => caps.urlFetchEnabled,
      ),
      const PlaceholderReconstructor(),
    ]),
  ).start();
  runApp(GoodShareApp(
    repo: repo,
    handler: handler,
    collector: collector,
    mcp: mcp,
    caps: caps,
  ));
}

class GoodShareApp extends StatelessWidget {
  const GoodShareApp({
    super.key,
    required this.repo,
    required this.handler,
    required this.collector,
    required this.mcp,
    required this.caps,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final TextCollector collector;
  final McpController mcp;
  final AiCapabilities caps;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '拾贝',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00897B)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00897B),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: HomeShell(
        repo: repo,
        handler: handler,
        collector: collector,
        mcp: mcp,
        caps: caps,
      ),
    );
  }
}
