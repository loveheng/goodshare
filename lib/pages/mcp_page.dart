import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../service/mcp_controller.dart';

/// MCP 服务页：开关、端点、token、桌面接入指南。
class McpPage extends StatefulWidget {
  const McpPage({super.key, required this.controller});

  final McpController controller;

  @override
  State<McpPage> createState() => _McpPageState();
}

class _McpPageState extends State<McpPage> {
  bool _showToken = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle(bool on) async {
    setState(() => _busy = true);
    final error = on ? await widget.controller.enable() : null;
    if (!on) await widget.controller.disable();
    setState(() => _busy = false);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('MCP 服务启动失败：$error')),
      );
    }
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label 已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('MCP 服务')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          SwitchListTile(
            title: const Text('启用 MCP 服务'),
            subtitle: Text(c.running ? '运行中 · 端口 ${c.port}' : '未运行（前台服务保活，可切后台）'),
            value: c.running,
            onChanged: _busy ? null : _toggle,
          ),
          if (c.lastError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(c.lastError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const Divider(height: 24),
          FutureBuilder<String>(
            future: c.endpoint(),
            builder: (context, snap) {
              final url = snap.data ?? '…';
              return ListTile(
                leading: const Icon(Icons.lan_outlined),
                title: const Text('局域网端点'),
                subtitle: Text(url),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () => _copy(url, '端点'),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.usb),
            title: const Text('USB 端点（adb reverse）'),
            subtitle: const Text('http://127.0.0.1:8765/mcp\n手机连电脑后执行：adb reverse tcp:8765 tcp:8765'),
            isThreeLine: true,
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => _copy('adb reverse tcp:8765 tcp:8765', 'adb 命令'),
            ),
          ),
          const Divider(height: 24),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('访问令牌（X-Api-Key）'),
            subtitle: Text(_showToken ? (c.token ?? '') : '••••••••••••（点击右侧显示）'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showToken = !_showToken),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () => _copy(c.token ?? '', '令牌'),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: '重新生成（旧令牌立即失效）',
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('重新生成令牌？'),
                        content: const Text('已配置的桌面客户端需要更新 token 才能继续访问。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新生成')),
                        ],
                      ),
                    );
                    if (ok == true) await c.regenerateToken();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 24),
          ExpansionTile(
            leading: const Icon(Icons.help_outline),
            title: const Text('桌面 AI 客户端接入指南'),
            initiallyExpanded: true,
            children: [
              const _GuideSection(
                title: '1. USB 方式（推荐，无需同一 Wi-Fi）',
                body: '手机开启 USB 调试并连接电脑，执行：\n'
                    'adb reverse tcp:8765 tcp:8765\n'
                    '桌面端即可访问 http://127.0.0.1:8765/mcp',
              ),
              _GuideSection(
                title: '2. 局域网方式（同一 Wi-Fi）',
                body: '直接使用上方「局域网端点」地址。\n'
                    '电脑无法连通时，检查手机与电脑是否同一网段、'
                    '路由器是否开启了 AP 隔离。',
              ),
              _GuideSection(
                title: '3. stdio 型客户端（Claude Desktop / ZCode 等）',
                body: '使用仓库自带桥接脚本 mcp-bridge/stdio-bridge.mjs，配置示例：\n\n'
                    '{\n'
                    '  "mcpServers": {\n'
                    '    "goodshare": {\n'
                    '      "command": "node",\n'
                    '      "args": ["<仓库路径>/mcp-bridge/stdio-bridge.mjs"],\n'
                    '      "env": {\n'
                    '        "GOODSHARE_URL": "http://127.0.0.1:8765/mcp",\n'
                    '        "GOODSHARE_TOKEN": "<你的访问令牌>"\n'
                    '      }\n'
                    '    }\n'
                    '  }\n'
                    '}',
                copyText: '{\n'
                    '  "mcpServers": {\n'
                    '    "goodshare": {\n'
                    '      "command": "node",\n'
                    '      "args": ["<仓库路径>/mcp-bridge/stdio-bridge.mjs"],\n'
                    '      "env": {\n'
                    '        "GOODSHARE_URL": "http://127.0.0.1:8765/mcp",\n'
                    '        "GOODSHARE_TOKEN": "<你的访问令牌>"\n'
                    '      }\n'
                    '    }\n'
                    '  }\n'
                    '}',
              ),
              const _GuideSection(
                title: '可用工具',
                body: 'list_items：检索/浏览收集内容（关键词、类型、分页）\n'
                    'get_item：读取全文，图片会返回图像内容\n'
                    'add_item：让 AI 帮你把内容存进来',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuideSection extends StatelessWidget {
  const _GuideSection({required this.title, required this.body, this.copyText});

  final String title;
  final String body;
  final String? copyText;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(body, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4)),
      ),
      isThreeLine: true,
      trailing: copyText == null
          ? null
          : IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () => Clipboard.setData(ClipboardData(text: copyText!)),
            ),
    );
  }
}
