import 'dart:async';

import 'package:flutter/material.dart';

import 'action/item_action_handler.dart';
import 'app/lifecycle_manager.dart';
import 'ui/privacy_blur_overlay.dart';
import 'ai/asr_reconstructor.dart';
import 'ai/ai_queue_service.dart';
import 'ai/capabilities.dart';
import 'ai/llm.dart';
import 'ai/llm_model_manager.dart';
import 'ai/llm_reconstructor.dart';
import 'ai/clip_reconstructor.dart';
import 'ai/model_manager.dart';
import 'ai/ocr_reconstructor.dart';
import 'ai/palette_reconstructor.dart';
import 'ai/image_label_reconstructor.dart';
import 'ai/barcode_reconstructor.dart';
import 'ai/text_analysis_capability.dart';
import 'ai/document_scan_capability.dart';
import 'ai/queue_consumer.dart';
import 'ai/reconstructor.dart';
import 'ai/translate_reconstructor.dart';
import 'ai/translation.dart';
import 'ai/translation_mlkit.dart';
import 'data/db.dart';
import 'data/repository.dart';
import 'pages/home_shell.dart';
import 'service/mcp_controller.dart';
import 'share/share_intake.dart';
import 'share/text_collector.dart';
import 'sync/backup_service.dart';
import 'update/remote_config_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 必须在 runApp 之前注册生命周期观察者，确保完整捕获启动期
  // inactive→resumed 序列，PrivacyBlurOverlay 能正确回到前台
  AppLifecycleManager.instance.init();
  // 规则二：限制图片缓存水位，长列表缩略图不会撑爆内存（默认 1000 张 / 100MB 过高）
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 100 << 20 // 100MB
    ..maximumSize = 500; // 缩略图体积小，允许较多条目常驻缓存
  final repo = Repository();
  // 预热数据库，避免首页先闪空态；顺带物理清理超过 30 天的已删条目
  await Db.instance();
  await repo.purgeDeleted();
  // 动作层先建：摄入（TextCollector/ShareIntake）与 MCP 共用同一写入口
  // aiQueue 用 late：handler 的 onEnqueued 闭包延迟引用，装配期（下方）才赋值
  late final AiQueueService aiQueue;
  final handler = ItemActionHandler(repo, onEnqueued: () => aiQueue.kick());
  final collector = TextCollector(handler);
  await collector.load();
  final caps = AiCapabilities();
  await caps.load();
  // 本机能力检测：首次执行后持久化，此后不再检测
  await caps.ensureDetected();
  // 翻译层装配（骨架期：ML Kit 引擎 + Noop 兜底，真离线模型后续按接口插拔）
  final translationEngine = MlKitTranslationEngine(targetLang: () => caps.targetLang);
  final translationRouter = TranslationRouter([translationEngine]);
  caps.router = translationRouter;
  caps.engine = translationEngine;
  final translationService = TranslationService(
    router: translationRouter,
    isEnabled: () => caps.translationEnabled,
    targetLang: () => caps.targetLang,
  );
  final mcp = McpController(repo: repo);
  await mcp.load();
  await RemoteConfigStore.instance.load();
  // S3 备份（2026-09-29）：独立状态机，不进 ai_task_queue；配置加载后设置页即可用
  final backup = BackupService(repo);
  await backup.load();
  final models = ModelManager();
  await models.load();
  final llmModels = LlmModelManager();
  await llmModels.load();
  await ShareIntake(handler, collector).init();
  // AI 队列消费者：v1 = 图片 ML Kit OCR + 音频 Sherpa 离线转写（均受设置开关门控）
  // + 链接离线抓取 + 其余占位复制
  final llmEngine = ChannelLlmEngine();
  // 文档扫描能力实例：同时注入 caps（UI 取用）与注册表（能力清单），保持单例
  final docScan = DocumentScanCapability();
  caps.documentScan = docScan;
  final consumer = QueueConsumer(
    repo,
    ReconstructorRegistry([
      OcrReconstructor(
        isOcrEnabled: () => caps.ocrEnabled,
        isUrlFetchEnabled: () => caps.urlFetchEnabled,
      ),
      // 图片分类（ML Kit Image Labeling，2026-09-29）：仅手动触发，base 模型离线可用
      ImageLabelCapability(),
      // 图片主色提取（palette_generator，2026-09-30 V3）：摄入自动入队（非模型推理）
      const PaletteReconstructor(),
      BarcodeReconstructor(),
      // 文本分析（ML Kit Language ID + Entity Extraction，2026-09-29）：仅笔记，离线
      TextAnalysisCapability(),
      // 文档扫描（ML Kit Document Scanner，2026-09-29）：前台相机流，GMS 设备可用，
      // 仅 UI 取用（caps.documentScan），不进队列路由
      docScan,
      AsrReconstructor(
        isAsrEnabled: () => caps.asrEnabled,
        models: models,
        translation: translationService,
        subtitleMode: () => caps.subtitleMode,
      ),
      TranslationReconstructor(service: translationService),
      // 端侧 LLM（2026-09-28）：摘要（summary_md）与关键词提取，均由显式命令入队
      // 视频切片（2026-09-29）：区间音轨→ASR→LLM 摘要，产出合并进 clips_json
      LlmReconstructor(engine: llmEngine),
      ClipReconstructor(
        engine: llmEngine,
        models: models,
        isAsrEnabled: () => caps.asrEnabled,
      ),
      const PlaceholderReconstructor(),
    ]),
    handler,
  );
  consumer.start();
  // 第 3 档：前台服务保活 + 设备状态感知调度 + 内存压力优雅中断
  // （consumer 启动 / 僵尸回收 / resumed 排空均收口进 AiQueueService）
  aiQueue = AiQueueService(repo: repo, consumer: consumer, mcp: mcp);
  consumer.canProcess = () async => aiQueue.inferenceAllowed;
  await aiQueue.init();
  runApp(GoodShareApp(
    repo: repo,
    handler: handler,
    collector: collector,
    mcp: mcp,
    caps: caps,
    models: models,
    llmModels: llmModels,
    aiQueue: aiQueue,
    backup: backup,
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
    required this.models,
    required this.llmModels,
    required this.aiQueue,
    required this.backup,
  });

  final Repository repo;
  final ItemActionHandler handler;
  final TextCollector collector;
  final McpController mcp;
  final AiCapabilities caps;
  final ModelManager models;
  final LlmModelManager llmModels;
  final AiQueueService aiQueue;
  final BackupService backup;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '拾贝',
      debugShowCheckedModeBanner: false,
      // 规则五：全局钳制字号缩放上限 1.5x，避免系统特大字体下 RenderFlex overflow
      builder: (context, child) {
        final data = MediaQuery.of(context);
        return MediaQuery(
          data: data.copyWith(
            textScaler: data.textScaler.clamp(minScaleFactor: 1.0, maxScaleFactor: 1.5),
          ),
          child: PrivacyBlurOverlay(child: child!),
        );
      },
      // 2026-09-30 mymind 视觉基准（ui-spec §2.1）：恒定暗色 + 三阶色阶分层
      // （底 / 卡 / 浮）+ 单一橘红强调色。dynamic_color / 明暗跟随已废弃；
      // 亮色模式不做。ColorScheme.dark 全量 override，M3 seed 派生色不再露出。
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          // 色阶三层：底（最深）→ 卡片 → 浮层（sheet/dialog）。
          surface: Color(0xFF15171E),
          surfaceContainerLowest: Color(0xFF101218),
          surfaceContainerLow: Color(0xFF1C1F27),
          surfaceContainer: Color(0xFF1C1F27),
          surfaceContainerHigh: Color(0xFF242833),
          surfaceContainerHighest: Color(0xFF2A2F3B),
          // 单一强调色：橘红仅用于动作与选中（ui-spec §2.1）。
          primary: Color(0xFFFF5A1E),
          onPrimary: Color(0xFFFFFFFF),
          primaryContainer: Color(0xFF3D1D0E),
          onPrimaryContainer: Color(0xFFFFB59A),
          secondary: Color(0xFFFF5A1E),
          onSecondary: Color(0xFFFFFFFF),
          // 文字色阶：暖白正文（非纯白），次级灰阶递减。
          onSurface: Color(0xFFE8E4DC),
          onSurfaceVariant: Color(0xFF9BA0AC),
          outline: Color(0xFF3A3F4C),
          error: Color(0xFFFF5370),
          onError: Color(0xFFFFFFFF),
        ),
        scaffoldBackgroundColor: const Color(0xFF15171E),
      ),
      // 恒定暗色：不跟随系统（ui-spec §2.1 拍板）。
      themeMode: ThemeMode.dark,
      home: HomeShell(
        repo: repo,
        handler: handler,
        collector: collector,
        mcp: mcp,
        caps: caps,
        models: models,
        llmModels: llmModels,
        aiQueue: aiQueue,
        backup: backup,
      ),
    );
  }
}
