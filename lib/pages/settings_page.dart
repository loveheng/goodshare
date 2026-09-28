import 'package:flutter/material.dart';

import '../action/item_action_handler.dart';
import '../data/repository.dart';
import '../ui/drawer_menu_button.dart';
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
import 'mcp_page.dart';
import 'recent_deleted_page.dart';
import 'update_page.dart';

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
    this.onOpenDrawer,
  });

  final ItemActionHandler handler;
  final Repository repo;
  final AiCapabilities caps;
  final TextCollector collector;
  final McpController mcp;
  final ModelManager models;
  final LlmModelManager llmModels;
  final AiQueueService aiQueue;
  final VoidCallback? onOpenDrawer;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _mode = widget.collector.mode;
  String _translationReason = '';

  @override
  void initState() {
    super.initState();
    widget.caps.addListener(_onCapsChanged);
    widget.models.addListener(_onModelsChanged);
    widget.llmModels.addListener(_onModelsChanged);
    widget.aiQueue.addListener(_onAiQueueChanged);
    widget.caps.ensureDetected(); // 首次检测后持久化；此后幂等
    _refreshTranslation(); // 翻译可用性与语言包状态是动态的，每次进入实时查
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '语言包已下载' : '下载失败（国内网络通常不可用）')),
    );
  }

  /// 端侧大模型下载（1-2GB 级单文件）：失败原因必须明说，不让用户对着无反应的按钮猜。
  Future<void> _onLlmDownload(LlmModel m) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('开始下载 ${m.name}（${_humanSize(m.sizeBytes)}）…')));
    try {
      await widget.llmModels.download(m);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('${m.name} 已就绪')));
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('下载失败：$e（可重试或换网络环境）')));
    }
  }

  /// 清除已下载模型（腾空间；历史产物不撤销，重新下载即可再用）。
  Future<void> _onLlmRemove(LlmModel m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除 ${m.name}？'),
        content: const Text('将释放模型占用的存储空间；已生成的摘要 / 关键词不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) await widget.llmModels.remove(m);
  }

  @override
  void dispose() {
    widget.caps.removeListener(_onCapsChanged);
    widget.models.removeListener(_onModelsChanged);
    widget.llmModels.removeListener(_onModelsChanged);
    widget.aiQueue.removeListener(_onAiQueueChanged);
    super.dispose();
  }

  void _onCapsChanged() {
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
      return _translationReason.isNotEmpty ? _translationReason : '无可用引擎，产物保留原文';
    }
    if (!caps.translationEnabled) return '已关闭';
    return '已就绪 · 目标 ${languageLabel(caps.targetLang)}';
  }

  String _bgProcessSubtitle() {
    if (widget.aiQueue.isMemoryPressure) return '内存紧张中，已暂停新任务（恢复后续跑）';
    if (!widget.aiQueue.backgroundProcessingEnabled) return '关闭（退后台后队列暂停，回前台继续）';
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
      appBar: AppBar(leading: drawerMenuLeading(widget.onOpenDrawer), title: const Text('设置')),
      body: ListView(
        children: [
          const _SectionHeader('MCP 网关'),
          ListTile(
            leading: Icon(
              Icons.cloud_sync_outlined,
              color: widget.mcp.running ? Theme.of(context).colorScheme.primary : null,
            ),
            title: const Text('服务与连接'),
            subtitle: Text(widget.mcp.running ? '运行中 · 端口 ${widget.mcp.port}' : '未运行'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => McpPage(controller: widget.mcp)),
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
          const _SectionHeader('翻译'),
          SwitchListTile(
            secondary: const Icon(Icons.translate),
            title: const Text('端侧翻译'),
            subtitle: Text(_translationSubtitle()),
            value: caps.translationEnabled && (caps.translationAvailable ?? false),
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
                  DropdownMenuItem(value: code, child: Text(languageLabel(code))),
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
                ButtonSegment(value: SubtitleMode.sourceOnly, label: Text('仅原文')),
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
              subtitle: const Text('ML Kit 语言包经 Google Play 下发，国内网络通常不可用；'
                  '失败时字幕与译文保留原文，不影响其它功能'),
              trailing: TextButton(
                onPressed: _onDownloadLanguagePack,
                child: const Text('下载'),
              ),
            ),
          const _SectionHeader('语音转写模型'),
          ...asrModels.map((m) => _AsrModelTile(
            model: m,
            models: widget.models,
            selected: widget.models.selectedId == m.id,
            onSelected: _onModelSelected,
          )),
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
            subtitle: const Text('下载模型后，详情页出现「摘要」「提取关键词」按钮；'
                'iOS 走系统模型（iOS 26+，无需下载）'),
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
            trailing: const Text('V2', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const _SectionHeader('隐私与保险箱'),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.fingerprint),
            title: const Text('FaceID 锁定保险箱'),
            subtitle: const Text('V3 生效（加密 + 生物识别门）'),
            trailing: const Text('V3', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ListTile(
            enabled: false,
            leading: const Icon(Icons.credit_card),
            title: const Text('身份证 / 银行卡默认打码'),
            subtitle: const Text('V2 生效（AI 管线产出时打码）'),
            trailing: const Text('V2', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const _SectionHeader('数据'),
          ListTile(
            leading: const Icon(Icons.merge_type_outlined),
            title: const Text('文本收集模式'),
            subtitle: Text(_mode == 'merge' ? '合并（同源 5 分钟内追加为一条）' : '分散（默认，每次一条）'),
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
            leading: const Icon(Icons.delete_sweep_outlined),
            title: const Text('最近删除'),
            subtitle: const Text('已删条目保留 30 天，可恢复或彻底删除'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                  builder: (_) => RecentDeletedPage(handler: widget.handler, repo: widget.repo)),
            ),
          ),
          const _SectionHeader('关于'),
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
          style: Theme.of(context)
              .textTheme
              .labelLarge
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
                      selected ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 20,
                      color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(model.name, style: Theme.of(context).textTheme.titleSmall),
                    ),
                    Text(
                      _humanSize(model.totalBytes),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  model.desc,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
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
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.error),
                          ),
                        ),
                      TextButton.icon(
                        icon: const Icon(Icons.download, size: 18),
                        label: Text(st.phase == DownloadPhase.error ? '重试' : '下载'),
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
                      selected ? Icons.radio_button_checked : Icons.radio_button_off,
                      size: 20,
                      color: selected ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(model.name, style: Theme.of(context).textTheme.titleSmall),
                    ),
                    Text(
                      _humanSize(model.sizeBytes),
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  model.desc,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
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
                      TextButton(onPressed: () => onRemove(model), child: const Text('删除')),
                    ],
                  )
                else if (ready)
                  Row(
                    children: [
                      Icon(Icons.check_circle, size: 16, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text('已下载', style: Theme.of(context).textTheme.bodySmall),
                      const Spacer(),
                      TextButton(onPressed: () => onRemove(model), child: const Text('删除')),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          selected ? '选中后详情页即可用（摘要 / 关键词）' : '点卡片选中；下载后生效',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
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
