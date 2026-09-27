import 'package:flutter/material.dart';

import 'data/db.dart';
import 'data/repository.dart';
import 'pages/list_page.dart';
import 'service/mcp_controller.dart';
import 'share/share_intake.dart';
import 'update/remote_config_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = Repository();
  // 预热数据库，避免首页先闪空态
  await Db.instance();
  final mcp = McpController(repo: repo);
  await mcp.load();
  await RemoteConfigStore.instance.load();
  await ShareIntake(repo).init();
  runApp(GoodShareApp(repo: repo, mcp: mcp));
}

class GoodShareApp extends StatelessWidget {
  const GoodShareApp({super.key, required this.repo, required this.mcp});

  final Repository repo;
  final McpController mcp;

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
      home: ListPage(repo: repo, mcp: mcp),
    );
  }
}
