import 'package:flutter/material.dart';

import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../share/text_collector.dart';
import '../service/mcp_controller.dart';
import 'mcp_page.dart';
import 'recent_deleted_page.dart';
import 'update_page.dart';

/// 设置页（设计 §5 设置树）。
/// AI 能力开关：首次进入触发本机检测并持久化（之后不再检测），
/// 无能力小字提示并置灰，有能力默认开启（2026-09-27 决策）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.repo,
    required this.caps,
    required this.collector,
    required this.mcp,
  });

  final Repository repo;
  final AiCapabilities caps;
  final TextCollector collector;
  final McpController mcp;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late String _mode = widget.collector.mode;

  @override
  void initState() {
    super.initState();
    widget.caps.addListener(_onCapsChanged);
    widget.caps.ensureDetected(); // 首次检测后持久化；此后幂等
  }

  @override
  void dispose() {
    widget.caps.removeListener(_onCapsChanged);
    super.dispose();
  }

  void _onCapsChanged() {
    if (mounted) setState(() {});
  }

  String _ocrSubtitle() {
    final caps = widget.caps;
    if (!caps.detected) return '能力检测中…';
    if (caps.ocrAvailable == false) return '本机未检测到 Google 服务，图片 OCR 不可用';
    if (!caps.ocrEnabled) return '已关闭';
    return '本机支持（GMS 端侧识别）';
  }

  String _sttSubtitle() {
    final caps = widget.caps;
    if (!caps.detected) return '能力检测中…';
    if (caps.sttAvailable == false) return '本机不支持端侧语音转写，仅保存音频';
    if (!caps.sttEnabled) return '已关闭';
    return '本机支持（系统语音识别，端侧优先）';
  }

  @override
  Widget build(BuildContext context) {
    final caps = widget.caps;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
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
            secondary: const Icon(Icons.graphic_eq),
            title: const Text('录音端侧转写'),
            subtitle: Text(_sttSubtitle()),
            value: caps.sttEnabled && (caps.sttAvailable ?? true),
            onChanged: caps.sttAvailable == false
                ? null
                : (v) => caps.setSttEnabled(v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.download_outlined),
            title: const Text('链接离线抓取正文'),
            subtitle: const Text('添加链接后自动抓取网页内容存为文本'),
            value: caps.urlFetchEnabled,
            onChanged: (v) => caps.setUrlFetchEnabled(v),
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
                  builder: (_) => RecentDeletedPage(repo: widget.repo)),
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
