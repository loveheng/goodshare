import 'package:flutter/material.dart';

import '../ui/knot_illustration.dart';
import '../ui/tokens.dart' show Insets, Radii;

/// 新建工作区整页（2026-10-01 拍板，mymind「Create new space」布局参照）：
/// 全屏居中构图——顶部三环绳结插画（箭头+序号保留，「把散落的条目打成结」
/// 的工作区隐喻，ui-spec §2.4）→ 衬线标题 → 定位语 → 大号描边名称框 →
/// 单一橘红胶囊主按钮；右上角 X 关闭（关闭语义，非导航返回，ui-spec §3
/// 例外口径），系统手势返回同样可用。品牌符号鹦鹉螺已升任 app 启动图标。
///
/// 本页**只产名称**（pop 回字符串），写路径留在 WorkspacePage 走命令
/// （goodshare-arch：UI 不持写路径）。创建走 `CreateWorkspaceCommand`；
/// [initialName] 非空即重命名模式（标题/按钮切换、创建定位语隐藏），
/// 写路径走 `RenameWorkspaceCommand`——同一表单双语义，弹层入口见
/// workspace_page 长按菜单（docs/design/workspace.md §3.1）。
/// V3 口子：工作区长出图标/配色/描述等属性时，属性步就长在本页（mymind 的
/// NEXT STEP 同位）。
class WorkspaceCreatePage extends StatefulWidget {
  const WorkspaceCreatePage({
    super.key,
    this.initialName,
    this.title = '新建工作区',
    this.cta = '创建',
  });

  /// 非空 = 重命名模式（预填旧名，隐藏创建定位语）。
  final String? initialName;
  final String title;
  final String cta;

  @override
  State<WorkspaceCreatePage> createState() => _WorkspaceCreatePageState();
}

class _WorkspaceCreatePageState extends State<WorkspaceCreatePage> {
  late final _name = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('先给工作区起个名字')));
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
            tooltip: '关闭',
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 居中：滚动视口给子级的是无界高度，裸 Center 撑不满会顶到上沿——
            // 以 minHeight 撑满可视区再居中；键盘弹起（resizeToAvoidBottomInset
            // 缩小可视区）时自动在剩余空间内居中，内容超高仍可滚。
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.lg,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Center(child: KnotIllustration(height: 96)),
                          const SizedBox(height: Insets.lg),
                          Text(
                            widget.title,
                            textAlign: TextAlign.center,
                            style: textTheme.headlineMedium?.copyWith(
                              fontFamily: 'serif',
                            ),
                          ),
                          // 创建定位语仅新建模式显示（重命名不需要产品定调）
                          if (widget.initialName == null) ...[
                            const SizedBox(height: Insets.md),
                            Text(
                              // 两句各占一行、居中：短句定调 + 长句阐述的
                              // 「短—长」节奏；层级靠行长对比，不加配色强调
                              '聚合点滴记录与热爱。\n不止是为了归档过去，更是为了启发未来。',
                              textAlign: TextAlign.center,
                              style: textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                height: 1.6,
                              ),
                            ),
                          ],
                          const SizedBox(height: Insets.xxl),
                          TextField(
                            controller: _name,
                            autofocus: true,
                            textAlign: TextAlign.center,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) => _create(),
                            style: textTheme.titleMedium,
                            decoration: InputDecoration(
                              hintText: '工作区名称',
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: Insets.lg,
                                vertical: Insets.lg,
                              ),
                              border: const OutlineInputBorder(
                                borderRadius: BorderRadius.all(
                                  Radius.circular(Radii.lg),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: Insets.xl),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _name,
                            builder: (context, value, _) {
                              final ready = value.text.trim().isNotEmpty;
                              return FilledButton(
                                // 名称空 = 按钮不可点（真正的承诺门）；SnackBar 兜
                                // onSubmitted 空回车的边角。形态继承主题大圆角矩形
                                onPressed: ready ? _create : null,
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(52),
                                ),
                                child: Text(widget.cta),
                              );
                            },
                          ),
                          const SizedBox(height: Insets.xxl),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
