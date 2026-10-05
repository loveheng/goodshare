import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../ui/slogans.dart';
import '../ai/ai_queue_service.dart';
import '../ai/asr_model.dart';
import '../ai/capabilities.dart';
import '../ai/language_codes.dart';
import '../ai/llm_model.dart';
import '../ai/llm_model_manager.dart';
import '../ai/model_manager.dart';
import '../ai/subtitle.dart';
import '../share/text_collector.dart';
import '../service/mcp_controller.dart';
import '../service/settings_store.dart';
import '../ui/confirm_dialog.dart';
import '../sync/backup_service.dart';
import 'attach_migration_page.dart';
import 'mcp_page.dart';
import 'recent_deleted_page.dart';
import 'update_page.dart';

/// tonal 按钮按压=底色实色加深（主题层按压反馈纪律的全局 pressed 色是
/// 橘红系、只对 Filled 主色生效；tonal 底是暖棕，需局部深一档，禁半透明罩）。
ButtonStyle _tonalPressStyle(BuildContext context) => ButtonStyle(
  backgroundColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.pressed)
        ? Color.alphaBlend(
            Colors.black.withValues(alpha: 0.18),
            Theme.of(context).colorScheme.secondaryContainer,
          )
        : null,
  ),
);

/// 设置页（设计 §5 设置树）。
/// AI 能力开关：首次进入触发本机检测并持久化（之后不再检测），
/// 无能力小字提示并置灰，有能力默认开启（2026-09-27 决策）。
/// 语音转写模型管理：档位选择 + 按需下载（2026-09-28）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.handler,
    required this.repo,
    required this.caps,
    required this.collector,
    required this.mcp,
    required this.models,
    required this.llmModels,
    required this.aiQueue,
    required this.backup,
  });

  final ItemActionHandler handler;
  final Repository repo;
  final AiCapabilities caps;
  final TextCollector collector;
  final McpController mcp;
  final ModelManager models;
  final LlmModelManager llmModels;
  final AiQueueService aiQueue;
  final BackupService backup;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _mode = widget.collector.mode;
  String _translationReason = '';
  bool _machineModeEnabled = false;

  @override
  void initState() {
    super.initState();
    widget.caps.addListener(_onCapsChanged);
    widget.models.addListener(_onModelsChanged);
    widget.llmModels.addListener(_onModelsChanged);
    widget.aiQueue.addListener(_onAiQueueChanged);
    widget.backup.addListener(_onBackupChanged);
    widget.caps.ensureDetected(); // 首次检测后持久化；此后幂等
    _refreshTranslation(); // 翻译可用性与语言包状态是动态的，每次进入实时查
    getMachineModeEnabled().then((v) {
      if (mounted) setState(() => _machineModeEnabled = v);
    });
  }

  Future<void> _refreshTranslation() async {
    await widget.caps.checkTranslationAvailable();
    final reason = await widget.caps.translationUnavailableReason();
    if (!mounted) return;
    setState(() => _translationReason = reason ?? '');
  }

  Future<void> _onDownloadLanguagePack() async {
    final ok = await widget.caps.downloadLanguagePack();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(ok ? '语言包已下载' : '下载失败（国内网络通常不可用）')));
  }

  /// 端侧大模型下载（1-2GB 级单文件）：失败原因必须明说，不让用户对着无反应的按钮猜。
  Future<void> _onLlmDownload(LlmModel m) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('开始下载 ${m.name}（${_humanSize(m.sizeBytes)}）…')),
    );
    try {
      await widget.llmModels.download(m);
      messenger.hideCurrentSnackBar();
      // 基于真实就绪态反馈：取消/未完成时不误报「已就绪」，可重试续传
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            widget.llmModels.isReady(m)
                ? '${m.name} 已就绪'
                : '${m.name} 下载已取消/未完成，可重试续传',
          ),
        ),
      );
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('下载失败：$e（可重试或换网络环境）')));
    }
  }

  /// 清除已下载模型（腾空间；历史产物不撤销，重新下载即可再用）。
  Future<void> _onLlmRemove(LlmModel m) async {
    final confirmed = await confirmDialog(
      context,
      title: '删除 ${m.name}？',
      content: '将释放模型占用的存储空间；已生成的摘要 / 关键词不受影响。',
      confirmText: '删除',
      danger: true,
    );
    if (confirmed == true) await widget.llmModels.remove(m);
  }

  @override
  void dispose() {
    widget.caps.removeListener(_onCapsChanged);
    widget.models.removeListener(_onModelsChanged);
    widget.llmModels.removeListener(_onModelsChanged);
    widget.aiQueue.removeListener(_onAiQueueChanged);
    widget.backup.removeListener(_onBackupChanged);
    super.dispose();
  }

  void _onCapsChanged() {
    if (mounted) setState(() {});
  }

  void _onBackupChanged() {
    if (mounted) setState(() {});
  }

  void _onModelsChanged() {
    if (mounted) setState(() {});
  }

  void _onAiQueueChanged() {
    if (mounted) setState(() {});
  }

  String _ocrSubtitle() {
    final caps = widget.caps;
    if (!caps.detected) return '能力检测中…';
    if (caps.ocrAvailable == false) return '本机 OCR 不可用';
    if (!caps.ocrEnabled) return '已关闭';
    return '本机支持（内置离线识别库）';
  }

  String _asrSubtitle() {
    final m = widget.models;
    final sel = m.selectedModel;
    final st = m.stateOf(sel);
    if (st.isDownloading) return '下载中 ${(st.progress * 100).round()}%';
    if (st.isReady) return '使用 ${sel.name}（离线识别，无隐私上传）';
    if (st.phase == DownloadPhase.error) return '上次下载失败：${st.error}';
    return '需先下载模型（${_humanSize(sel.totalBytes)}）';
  }

  String _translationSubtitle() {
    final caps = widget.caps;
    if (caps.translationAvailable == null) return '检测中…';
    if (caps.translationAvailable == false) {
      return _translationReason.isNotEmpty
          ? _translationReason
          : '无可用引擎，产物保留原文';
    }
    if (!caps.translationEnabled) return '已关闭';
    return '已就绪 · 目标 ${languageLabel(caps.targetLang)}';
  }

  String _bgProcessSubtitle() {
    if (widget.aiQueue.isMemoryPressure) return '内存紧张中，已暂停新任务（恢复后续跑）';
    if (!widget.aiQueue.backgroundProcessingEnabled) {
      return '关闭（退后台后队列暂停，回前台继续）';
    }
    return '退后台由前台服务保活，OCR / 转写 / 抓取继续处理';
  }

  /// 开关打开且当前档位模型已下载时，重入队存量未处理音频（模型就绪后自动转写）。
  Future<void> _onAsrSwitch(bool v) async {
    await widget.caps.setAsrEnabled(v);
    if (!v) return;
    final sel = widget.models.selectedModel;
    if (!await widget.models.isDownloaded(sel)) return;
    await _requeuePendingAudio();
  }

  /// 切换档位：当前档位已下载则直接切换并重入队存量未处理音频；
  /// 未下载仅切换选择（用户再点下载）。
  Future<void> _onModelSelected(String id) async {
    await widget.models.selectModel(id);
    final sel = widget.models.selectedModel;
    if (!await widget.models.isDownloaded(sel)) return;
    await _requeuePendingAudio();
  }

  /// 把尚未产出人类态的音频条目重新入队（幂等：已转写的不会重复处理）。
  Future<void> _requeuePendingAudio() async {
    await widget.handler.requeueUnprocessedAudio();
  }

  @override
  Widget build(BuildContext context) {
    final caps = widget.caps;
    return Scaffold(
      // ☰ 只保留在「全部」页（2026-09-30 用户拍板）；设置页顶栏纯标题，
      // 抽屉从「全部」页开。
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('MCP 网关'),
          ListTile(
            leading: Icon(
              Icons.cloud_sync_outlined,
              color: widget.mcp.running
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: const Text('服务与连接'),
            subtitle: Text(
              widget.mcp.running ? '运行中 · 端口 ${widget.mcp.port}' : '未运行',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => McpPage(controller: widget.mcp),
              ),
            ),
          ),
          const _SectionHeader('AI 模式'),
          SwitchListTile(
            secondary: const Icon(Icons.document_scanner_outlined),
            title: const Text('图片 OCR'),
            subtitle: Text(_ocrSubtitle()),
            value: caps.ocrEnabled && (caps.ocrAvailable ?? true),
            onChanged: caps.ocrAvailable == false
                ? null // 无能力：置灰 + 小字提示
                : (v) => caps.setOcrEnabled(v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.download_outlined),
            title: const Text('链接离线抓取正文'),
            subtitle: const Text('添加链接后自动抓取网页内容存为文本'),
            value: caps.urlFetchEnabled,
            onChanged: (v) => caps.setUrlFetchEnabled(v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.mic_external_on),
            title: const Text('录音/音频 端侧转写'),
            subtitle: Text(_asrSubtitle()),
            value: caps.asrEnabled,
            onChanged: _onAsrSwitch,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.cloud_done_outlined),
            title: const Text('退后台继续 AI 处理'),
            subtitle: Text(_bgProcessSubtitle()),
            value: widget.aiQueue.backgroundProcessingEnabled,
            onChanged: (v) => widget.aiQueue.setBackgroundProcessingEnabled(v),
          ),
          const _SectionHeader('高级'),
          SwitchListTile(
            secondary: const Icon(Icons.code_outlined),
            title: const Text('机器码（JSON 调试入口）'),
            subtitle: const Text('默认关闭；开启后详情页 ⋯ 菜单出现「机器码」项，切换人类态 / 机器态'),
            value: _machineModeEnabled,
            onChanged: (v) async {
              await setMachineModeEnabled(v);
              if (mounted) setState(() => _machineModeEnabled = v);
            },
          ),
          const _SectionHeader('翻译'),
          SwitchListTile(
            secondary: const Icon(Icons.translate),
            title: const Text('端侧翻译'),
            subtitle: Text(_translationSubtitle()),
            value:
                caps.translationEnabled && (caps.translationAvailable ?? false),
            onChanged: caps.translationAvailable == false
                ? null // 语言包未就绪：置灰 + 小字说明原因，不静默降级
                : (v) => caps.setTranslationEnabled(v),
          ),
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: const Text('目标语言'),
            subtitle: const Text('文本条目翻译与字幕译文的目标语种'),
            trailing: DropdownButton<String>(
              value: caps.targetLang,
              items: [
                for (final code in kTargetLanguages)
                  DropdownMenuItem(
                    value: code,
                    child: Text(languageLabel(code)),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                caps.setTargetLang(v);
                _refreshTranslation();
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.subtitles_outlined),
            title: const Text('字幕译文'),
            subtitle: const Text('转写出的字幕是否带译文（翻译不可用时自动只出原文）'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<SubtitleMode>(
              segments: const [
                ButtonSegment(
                  value: SubtitleMode.sourceOnly,
                  label: Text('仅原文'),
                ),
                ButtonSegment(value: SubtitleMode.bilingual, label: Text('双语')),
                ButtonSegment(value: SubtitleMode.separate, label: Text('分文件')),
              ],
              selected: {caps.subtitleMode},
              onSelectionChanged: (s) => caps.setSubtitleMode(s.first),
            ),
          ),
          if (caps.translationAvailable == false && caps.engine != null)
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: Text('下载${languageLabel(caps.targetLang)}语言包'),
              subtitle: const Text(
                'ML Kit 语言包经 Google Play 下发，国内网络通常不可用；'
                '失败时字幕与译文保留原文，不影响其它功能',
              ),
              trailing: TextButton(
                onPressed: _onDownloadLanguagePack,
                child: const Text('下载'),
              ),
            ),
          const _SectionHeader('语音转写模型'),
          ...asrModels.map(
            (m) => _AsrModelTile(
              model: m,
              models: widget.models,
              selected: widget.models.selectedId == m.id,
              onSelected: _onModelSelected,
            ),
          ),
          const _SectionHeader('端侧大模型'),
          // SoC 感知目录：NPU 专包仅对应机型可见（设计 §3.1），通用包恒可见
          FutureBuilder<List<LlmModel>>(
            future: widget.llmModels.visibleModels(),
            builder: (context, snap) => Column(
              children: [
                for (final m in (snap.data ?? const <LlmModel>[]))
                  _LlmModelTile(
                    model: m,
                    manager: widget.llmModels,
                    selected: widget.llmModels.selectedId == m.id,
                    onSelected: (id) => widget.llmModels.select(id),
                    onDownload: _onLlmDownload,
                    onRemove: _onLlmRemove,
                  ),
              ],
            ),
          ),
          ListTile(
            enabled: false,
            dense: true,
            leading: const Icon(Icons.psychology_alt_outlined),
            title: const Text('摘要 / 关键词提取'),
            subtitle: const Text(
              '下载模型后，详情页出现「摘要」「提取关键词」按钮；'
              'iOS 走系统模型（iOS 26+，无需下载）',
            ),
          ),
          ListTile(
            enabled: false,
            dense: true,
            leading: const Icon(Icons.graphic_eq),
            title: const Text('VAD 已内置'),
            subtitle: const Text('语音分段随 App 打包，字幕开箱即用（无需下载）'),
          ),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('离线 AI 双态重构（自动 / 强制 V1 / 尝试 V2）'),
            subtitle: const Text('V2 生效，当前为基础模式'),
            trailing: const Text(
              'V2',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const _SectionHeader('隐私与保险箱'),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.credit_card),
            title: const Text('身份证 / 银行卡默认打码'),
            subtitle: const Text('V2 生效（AI 管线产出时打码）'),
            trailing: const Text(
              'V2',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.merge_type_outlined),
            title: const Text('文本收集模式'),
            subtitle: Text(
              _mode == 'merge' ? '合并（同源 5 分钟内追加为一条）' : '分散（默认，每次一条）',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'scatter', label: Text('分散')),
                ButtonSegment(value: 'merge', label: Text('合并')),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) {
                setState(() => _mode = selection.first);
                widget.collector.setMode(selection.first);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_copy_outlined),
            title: const Text('附件迁移'),
            subtitle: const Text('把引用的分享原件转为本地持有，防源失效'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AttachMigrationPage(
                  handler: widget.handler,
                  repo: widget.repo,
                ),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('最近删除'),
            subtitle: const Text('已删条目保留 30 天，可恢复或彻底删除'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => RecentDeletedPage(
                  handler: widget.handler,
                  repo: widget.repo,
                ),
              ),
            ),
          ),
          const _SectionHeader('S3 备份'),
          _S3BackupSection(backup: widget.backup),
          const _SectionHeader('关于'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: PoeticText(sloganFor(SloganKeys.about), large: false),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('检查更新'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const UpdatePage()),
            ),
          ),
        ],
      ),
    );
  }
}

String _humanSize(int bytes) {
  final mb = bytes / 1024 / 1024;
  return mb >= 100 ? '${mb.round()}MB' : '${mb.toStringAsFixed(1)}MB';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// 三档模型选择卡片：选中态 + 状态/下载进度 + 下载/取消/清除操作（2026-09-28）。
class _AsrModelTile extends StatelessWidget {
  const _AsrModelTile({
    required this.model,
    required this.models,
    required this.selected,
    required this.onSelected,
  });

  final AsrModel model;
  final ModelManager models;
  final bool selected;
  final void Function(String id) onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final st = models.stateOf(model);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onSelected(model.id),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        model.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      _humanSize(model.totalBytes),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  model.desc,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                if (st.isDownloading)
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: st.progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${(st.progress * 100).round()}%'),
                      IconButton(
                        icon: const Icon(Icons.cancel, size: 18),
                        tooltip: '取消下载',
                        onPressed: () => models.cancelDownload(model.id),
                      ),
                    ],
                  )
                else if (st.isReady)
                  Row(
                    children: [
                      Icon(Icons.check_circle, size: 16, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text('已下载', style: Theme.of(context).textTheme.bodySmall),
                      const Spacer(),
                      TextButton(
                        onPressed: () => models.clearCache(model),
                        child: const Text('清除缓存'),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      if (st.phase == DownloadPhase.error)
                        Expanded(
                          child: Text(
                            '下载失败：${st.error}',
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.error),
                          ),
                        ),
                      TextButton.icon(
                        icon: const Icon(Icons.download, size: 18),
                        label: Text(
                          st.phase == DownloadPhase.error ? '重试' : '下载',
                        ),
                        onPressed: () => models.download(model),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 端侧大模型档位卡片（2026-09-28）：与 ASR 档位卡片同构——选中态 + 下载进度 + 清除。
/// 与 ASR 的差异：单文件整下（无逐文件断点续传），删除需二次确认（1-2GB 级文件）。
class _LlmModelTile extends StatelessWidget {
  const _LlmModelTile({
    required this.model,
    required this.manager,
    required this.selected,
    required this.onSelected,
    required this.onDownload,
    required this.onRemove,
  });

  final LlmModel model;
  final LlmModelManager manager;
  final bool selected;
  final void Function(String id) onSelected;
  final void Function(LlmModel m) onDownload;
  final void Function(LlmModel m) onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = manager.isReady(model);
    final stale = manager.isStale(model);
    final progress = manager.progressOf(model);
    final paused = manager.isPaused(model);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onSelected(model.id),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      size: 20,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        model.name,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Text(
                      _humanSize(model.sizeBytes),
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  model.desc,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                if (progress != null)
                  Row(
                    children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${(progress * 100).round()}%'),
                      IconButton(
                        icon: const Icon(Icons.pause, size: 18),
                        tooltip: '暂停',
                        onPressed: () => manager.cancelDownload(model.id),
                      ),
                    ],
                  )
                else if (paused)
                  // 用户暂停：.part 片段保留，点「继续」从断点续传
                  Row(
                    children: [
                      Icon(
                        Icons.pause_circle,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '已暂停（可继续）',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('继续'),
                        onPressed: () => onDownload(model),
                      ),
                      TextButton(
                        onPressed: () => onRemove(model),
                        child: const Text('删除'),
                      ),
                    ],
                  )
                else if (ready && stale)
                  // 云端 manifest 同 id 换了文件：旧文件照常可用（2026-09-29 拍板：
                  // 旧模型用得好好的不能不让用），更新与否用户自选——只提示不标红。
                  Row(
                    children: [
                      Icon(Icons.check_circle, size: 16, color: scheme.primary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '已下载 · 云端有新版本可更新',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.update, size: 18),
                        label: const Text('更新'),
                        onPressed: () => onDownload(model),
                      ),
                      TextButton(
                        onPressed: () => onRemove(model),
                        child: const Text('删除'),
                      ),
                    ],
                  )
                else if (ready)
                  Row(
                    children: [
                      Icon(Icons.check_circle, size: 16, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text('已下载', style: Theme.of(context).textTheme.bodySmall),
                      const Spacer(),
                      TextButton(
                        onPressed: () => onRemove(model),
                        child: const Text('删除'),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          selected ? '选中后详情页即可用（摘要 / 关键词）' : '点卡片选中；下载后生效',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.download, size: 18),
                        label: const Text('下载'),
                        onPressed: () => onDownload(model),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// S3 备份区块（2026-09-29，设计 docs/design/s3-backup.md §6/§7）：
/// 服务器配置（endpoint/bucket/region/AK/SK 掩码）+ 测试连接 + 手动备份/恢复（进度条/取消）。
/// 隐私边界明示：保险箱条目不备份（DB 快照含未加密正文，未加密远端不承载）。
class _S3BackupSection extends StatefulWidget {
  const _S3BackupSection({required this.backup});

  final BackupService backup;

  @override
  State<_S3BackupSection> createState() => _S3BackupSectionState();
}

class _S3BackupSectionState extends State<_S3BackupSection> {
  final _endpointCtrl = TextEditingController();
  final _bucketCtrl = TextEditingController();
  final _regionCtrl = TextEditingController();
  final _akCtrl = TextEditingController();
  final _skCtrl = TextEditingController();
  bool _obscure = true;
  String? _lastResult;
  BackupSizeEstimate? _estimate; // 备份前体积估算（null=未算出/算不出）
  bool _estimating = false;

  @override
  void initState() {
    super.initState();
    _endpointCtrl.text = widget.backup.endpoint ?? '';
    _bucketCtrl.text = widget.backup.bucket ?? '';
    _regionCtrl.text = widget.backup.region ?? '';
    // 体积估算要 stat 全部待传附件，放首帧后异步跑，不拖慢进入设置页
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadEstimate());
  }

  @override
  void dispose() {
    _endpointCtrl.dispose();
    _bucketCtrl.dispose();
    _regionCtrl.dispose();
    _akCtrl.dispose();
    _skCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    final messenger = ScaffoldMessenger.of(context);
    final endpoint = _endpointCtrl.text.trim();
    final bucket = _bucketCtrl.text.trim();
    if (endpoint.isEmpty || bucket.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请填写 endpoint 与 bucket')),
      );
      return;
    }
    try {
      await widget.backup.saveConfig(
        endpoint: endpoint,
        bucket: bucket,
        region: _regionCtrl.text.trim(),
        accessKey: _akCtrl.text.trim(),
        secretKey: _skCtrl.text,
      );
      messenger.showSnackBar(const SnackBar(content: Text('已保存，可点「测试连接」验证')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<void> _test() async {
    final messenger = ScaffoldMessenger.of(context);
    // 测试连接测的是「屏幕上的当前值」而非旧存档：先保存再测，
    // 避免用户改了输入框没点保存 → 测的还是旧配置 → 「我明明填了 https」的困惑
    final endpoint = _endpointCtrl.text.trim();
    final bucket = _bucketCtrl.text.trim();
    if (endpoint.isEmpty || bucket.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('请填写 endpoint 与 bucket')),
      );
      return;
    }
    try {
      await widget.backup.saveConfig(
        endpoint: endpoint,
        bucket: bucket,
        region: _regionCtrl.text.trim(),
        accessKey: _akCtrl.text.trim(),
        secretKey: _skCtrl.text,
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('正在测试连接…')));
    try {
      final msg = await widget.backup.testConnection();
      messenger.showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _backupNow() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await widget.backup.runBackup();
      messenger.showSnackBar(SnackBar(content: Text(r.message)));
      setState(() => _lastResult = r.message);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('备份启动失败：$e')));
    } finally {
      // 备份后附件集合可能变化（如新收进的视频），估算随之刷新
      await _loadEstimate();
    }
  }

  Future<void> _restore() async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await confirmDialog(
      context,
      title: '从 S3 恢复？',
      content: '将用备份覆盖本机全部数据（条目 / 附件 / 草稿 / 任务队列）。\n'
          '已收进的视频作为原始附件随备份恢复（引用型/未收进的仍需重新分享收集）；\n'
          '保险箱条目从未进备份，不受影响。建议先做一次备份。',
      confirmText: '确认恢复',
    );
    if (confirmed != true) return;
    try {
      final r = await widget.backup.runRestore();
      messenger.showSnackBar(SnackBar(content: Text(r.message)));
      setState(() => _lastResult = r.message);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('恢复启动失败：$e')));
    }
  }

  /// 字节体积人类可读（体积可见性：让用户看懂「多大」，而不是一串字节数）。
  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  /// 计算待上传体积（备份前可见性）。与 runBackup 同一收集器，只读 stat 不上传。
  Future<void> _loadEstimate() async {
    if (!widget.backup.hasConfig || _estimating) return;
    setState(() => _estimating = true);
    final est = await widget.backup.estimateBackup();
    if (!mounted) return;
    setState(() {
      _estimate = est;
      _estimating = false;
    });
  }

  String _estimateLabel() {
    if (_estimating && _estimate == null) return '正在计算待上传体积…';
    final e = _estimate;
    if (e == null) return '暂无法估算待上传体积';
    final video = e.videoCount > 0
        ? '（视频 ${e.videoCount} 个 · ${_fmtBytes(e.videoBytes)}）'
        : '';
    return '待上传 ${e.fileCount} 个文件 · ${_fmtBytes(e.totalBytes)}$video；远端已有的会增量跳过';
  }

  String _progressLabel(BackupProgress p) {
    final phase = switch (p.phase) {
      'snapshot' => '生成数据库快照',
      'attachments' => '上传附件',
      'db' => '上传数据库',
      'manifest' => '写入备份清单（提交）',
      'restore_manifest' => '校验备份清单',
      'restore_db' => '恢复数据库',
      'restore_attachments' => '恢复附件',
      _ => '',
    };
    final total = p.total > 0 ? ' $p.done/$p.total' : '';
    // 体积可见性的「备份中」一半：已传/总量，让用户看懂剩下多少
    final bytes = p.totalBytes > 0
        ? ' · ${_fmtBytes(p.transferredBytes)}/${_fmtBytes(p.totalBytes)}'
        : '';
    final cur = p.currentLabel.isNotEmpty ? '（${p.currentLabel}）' : '';
    return '$phase$total$bytes$cur';
  }

  @override
  Widget build(BuildContext context) {
    final backup = widget.backup;
    final busy = backup.busy;
    final scheme = Theme.of(context).colorScheme;
    final last = backup.lastBackup;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _endpointCtrl,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'S3 Endpoint',
              hintText: 'https://s3.example.com:9000',
              helperText:
                  'MinIO / NAS / R2 / B2 / OSS 等 S3 兼容服务（path-style）；'
                  'R2 填 https://<账户ID>.r2.cloudflarestorage.com',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _bucketCtrl,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Bucket',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _regionCtrl,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Region',
                    hintText: 'us-east-1',
                    helperText: 'Cloudflare R2 填 auto',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _akCtrl,
            enabled: !busy,
            decoration: const InputDecoration(
              labelText: 'Access Key',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _skCtrl,
            enabled: !busy,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Secret Key',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: busy ? null : _saveConfig,
                  style: _tonalPressStyle(context),
                  child: const Text('保存配置'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: busy ? null : _test,
                  style: _tonalPressStyle(context),
                  icon: const Icon(Icons.network_check, size: 18),
                  label: const Text('测试连接'),
                ),
              ),
            ],
          ),
        ),
        if (backup.hasConfig && !busy) ...[
          const SizedBox(height: 12),
          ListTile(
            dense: true,
            leading: const Icon(Icons.cloud_upload_outlined),
            title: const Text('立即备份'),
            subtitle: const Text(
              '数据库 + 附件增量上传；已收进的视频随备份上传（体积较大，首次备份较慢）；保险箱条目不备份（未加密）',
            ),
            trailing: FilledButton(
              onPressed: _backupNow,
              child: const Text('备份'),
            ),
          ),
          // 体积可见性（备份前）：把「本次要传多少、视频占多少」在点备份之前显性化——
          // 视频过准入门槛即进备份（video-subject.md §4），代价必须让用户先看见再决定。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _estimateLabel(),
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 16),
                  tooltip: '重新计算',
                  onPressed: _estimating ? null : _loadEstimate,
                ),
              ],
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.cloud_download_outlined),
            title: const Text('从备份恢复'),
            subtitle: const Text('用最近一次备份覆盖本机数据（保险箱不受影响）'),
            trailing: FilledButton.tonal(
              onPressed: _restore,
              style: _tonalPressStyle(context),
              child: const Text('恢复'),
            ),
          ),
        ],
        if (busy) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                LinearProgressIndicator(
                  value: backup.progress.total > 0
                      ? backup.progress.done / backup.progress.total
                      : null,
                ),
                const SizedBox(height: 6),
                Text(
                  _progressLabel(backup.progress),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 4),
                TextButton.icon(
                  onPressed: backup.cancel,
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('取消（远端旧备份不受影响）'),
                ),
              ],
            ),
          ),
        ],
        if (!busy && _lastResult != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _lastResult!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        if (!busy && last != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '最近备份：${_fmtBackupTs(last.ts)}（${last.itemCount} 条）',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

String _fmtBackupTs(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
