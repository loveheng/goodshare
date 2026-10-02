import 'package:flutter/foundation.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../models/item.dart';
import 'attachments.dart';
import 'attach_uri_channel.dart';
import 'image_aspect.dart';
import 'media_duration.dart';
import 'text_collector.dart';
import 'text_parse.dart';

/// 系统分享入口：把 receive_sharing_intent 的事件归一成 InboxItem 落库。
/// 附件会复制到 app 私有目录（documents/shares/），不依赖源 app 的 content URI。
/// 分层约定：文本/链接写 raw_content（经 TextCollector 支持合并模式），附件写
/// raw_file_path（每附件一条）；human_* 由 AI 队列占位管线填充，此处只入原始层并入队。
///
/// 入库一律经 `ItemActionHandler`（`CollectCommand`）——与手动添加、MCP `add_item` 同源，
/// 共享同一套防呆与入队出口（Human-AI 对称性：写必走动作层）。
class ShareIntake {
  ShareIntake(this._handler, this._collector, {this.referenceMode = true})
      : _attachUri = AttachUriChannel();

  final ItemActionHandler _handler;
  final TextCollector _collector;
  final AttachUriChannel _attachUri;

  /// 引用模式（content-pipeline §6/§7）：默认 true——分享摄入**不复制**原件，
  /// 直接引用源 URI 并标记 `attachState=ref`，app 不占用户存储。
  /// 复制模式（false）走旧路径 [copyToAppDir]，标记为 owned。
  ///
  /// ⚠️ 持久化 URI 权限（takePersistableUriPermission）与 content:// 可达性检测
  /// 依赖 Android SAF，需真机验证（本机无设备）。未实测前引用条目可能随源 app
  /// 回收权限而失效——属已知平台约束，非代码缺陷，详见 epic devlog。
  final bool referenceMode;
  bool _busy = false;

  /// 来源标识：插件 1.9.0 不提供来源 App 信息，统一记为「系统分享」便于溯源。
  static const _sourceApp = '系统分享';

  Future<void> init() async {
    // 冷启动（app 未运行时通过分享拉起）
    final initial = await ReceiveSharingIntent.instance.getInitialMedia();
    if (initial.isNotEmpty) {
      await _handle(initial);
      await ReceiveSharingIntent.instance.reset();
    }
    // app 存活期间收到的新分享
    ReceiveSharingIntent.instance.getMediaStream().listen(
      (list) async {
        if (list.isNotEmpty) {
          await _handle(list);
          await ReceiveSharingIntent.instance.reset();
        }
      },
      onError: (Object e) => debugPrint('[ShareIntake] stream error: $e'),
    );
  }

  /// 测试入口：[init] 事件流的处理主体（classify + 分类型入库）。
  /// 与 [classify] 同为 @visibleForTesting 口径。
  @visibleForTesting
  Future<void> handleForTest(List<SharedMediaFile> medias) => _handle(medias);

  Future<void> _handle(List<SharedMediaFile> medias) async {
    if (_busy) return; // 事件流可能重放，防重复入库
    _busy = true;
    try {
      final (texts, files) = classify(medias);

      for (final f in files) {
        final t = _typeOfMedia(f);
        // 尺寸前置（rich-text-component.md §6.1 V1）：图片摄入时解码头取宽高比，
        // 渲染处占位消灭加载抖动；探测失败为 null 不挡摄入。
        final aspect = t == InboxItem.typeImage ? await probeImageAspect(f.path) : null;
        // 时长预存（rich-text-media.md §3）：音视频摄入时探测一次，渲染处秒显
        // 进度条总时长、省去每次播放前临时建播放器探测；探测失败为 null 不挡摄入。
        final durationMs = (t == InboxItem.typeAudio || t == InboxItem.typeVideo)
            ? await probeMediaDuration(f.path, t)
            : null;
        // PDF 拍板（2026-10-02，content-pipeline §6）：一律持有 owned 作事实来源，
        // 抽取文本只是派生视图（可重跑 reprocess）——有损转换 × 释放不可逆 = 信任
        // 击穿，故持有语义与引用模式开关无关，PDF 恒走复制。
        if (referenceMode && !_isPdf(f)) {
          // 引用模式：不复制，直接引用源 URI（content:// 或 file://），
          // 标记 ref——app 不占用户存储（content-pipeline §6）。
          // 摄入时即刻尝试持久化读权限（takePersistableUriPermission）：
          // 授权成功则 URI 跨重启可达，授权失败（源 app 未授 persistable
          // flag）保持 ref 语义——失效时由迁移清单页转 owned 兜底。
          final persisted = await _attachUri.persistUri(f.path);
          if (!persisted) {
            debugPrint('[ShareIntake] persistable grant unavailable: ${f.path}');
          }
          await _handler.execute(CollectCommand(
            itemType: t,
            sourceApp: _sourceApp,
            humanTitle: _baseName(f.path),
            rawFilePath: f.path,
            attachState: InboxItem.attachRef,
            aspectRatio: aspect,
            mediaDurationMs: durationMs,
          ));
        } else {
          // 复制路径：PDF（恒走）或引用模式关闭时的全部附件。
          // 源文件失效（如临时 URI 已被回收）则丢弃该附件。
          final saved = await copyToAppDir(f.path);
          if (saved == null) continue;
          await _handler.execute(CollectCommand(
            itemType: t,
            sourceApp: _sourceApp,
            humanTitle: _baseName(f.path),
            rawFilePath: saved,
            aspectRatio: aspect,
            mediaDurationMs: durationMs,
          ));
        }
      }

      for (final t in texts) {
        // 文本走 TextCollector：分散/合并模式与入队在其内统一处理
        await _collector.collectText(t, sourceApp: _sourceApp);
      }
    } catch (e) {
      debugPrint('[ShareIntake] handle error: $e');
    } finally {
      _busy = false;
    }
  }

  /// 事件分类：文本进 texts、附件进 files。
  /// 插件 1.9.0 Android 侧（ReceiveSharingIntentPlugin.toJsonObject）把分享文本
  /// 放进 path（`path ?: text`），message 恒为 null——文本类型必须以 path 为准，
  /// message 仅作未来版本兜底，字段以 pub 缓存插件源码为准。
  @visibleForTesting
  static (List<String>, List<SharedMediaFile>) classify(List<SharedMediaFile> medias) {
    final texts = <String>[];
    final files = <SharedMediaFile>[];
    for (final m in medias) {
      switch (m.type) {
        case SharedMediaType.text:
          final t = (m.message?.trim().isNotEmpty ?? false) ? m.message!.trim() : m.path.trim();
          if (t.isNotEmpty) texts.add(t);
        case SharedMediaType.url:
          if (m.path.trim().isNotEmpty) texts.add(m.path.trim());
        case SharedMediaType.image:
        case SharedMediaType.video:
        case SharedMediaType.file:
          files.add(m);
      }
    }
    return (texts, files);
  }

  /// 文本/链接归一（薄委托，供既有测试使用；实现见 text_parse.dart）。
  ({String type, String? title, String text}) parseText(String raw) => parseCollectedText(raw);

  String _typeOfMedia(SharedMediaFile m) => switch (m.type) {
        SharedMediaType.image => InboxItem.typeImage,
        SharedMediaType.video => InboxItem.typeVideo,
        SharedMediaType.file => InboxItem.typeDocument,
        SharedMediaType.url => InboxItem.typeUrl,
        SharedMediaType.text => InboxItem.typeNote,
      };

  /// PDF 判定：mimeType 优先（application/pdf），缺失时按扩展名兜底
  /// （部分分享方不填 mimeType）。PDF 恒走持有路径（content-pipeline §6）。
  bool _isPdf(SharedMediaFile f) {
    final mime = f.mimeType?.toLowerCase();
    if (mime != null) return mime == 'application/pdf';
    return f.path.toLowerCase().endsWith('.pdf');
  }

  String _baseName(String path) {
    final base = path.split('/').last;
    return base.length > 60 ? '${base.substring(0, 60)}…' : base;
  }
}
