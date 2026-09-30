---
dev-loop: lessons
format: v1
epic: global
total-merged: 1
last-merge: 2026-09-29
---

# lessons

按模块归类的避坑规则正文（正文行禁用 `- [` 开头——该前缀专属底部追加区）

## share_intake

真机文本分享静默丢失（无报错、无入库） ➔ receive_sharing_intent 1.9.0 Android 端把 EXTRA_TEXT 写进 SharedMediaFile.path 而非 message，按字段名想当然读取落空 ➔ 第三方插件的数据形状必须读 pub 缓存里的平台实现源码取证，不能凭模型字段名/旧版本记忆假设；跨端行为差异用回归测试钉住真实 payload 形状 (Ref: goodshare)

## 构建

release 构建 R8 报 missing class（ML Kit 脚本识别器） ➔ google_mlkit_text_recognition 仅自带 latin 脚本依赖 ➔ 所需脚本（中文）在 app 级 build.gradle.kts 引入 GMS 依赖，未用脚本在 proguard-rules.pro dontwarn (Ref: goodshare)

本机 flutter build 报 NDK LicenceNotAcceptedException（指向 /usr/lib/android-sdk） ➔ android/local.properties 的 sdk.dir 残留系统 SDK 路径而非 ~/android-sdk ➔ 构建类故障先查 local.properties 的 sdk.dir 与 ANDROID_HOME 指向，别先怀疑项目配置 (Ref: goodshare)

## Flutter

父级 setState 不触发缓存子页重建（设置页 SegmentedButton 选中态不更新） ➔ HomeShell _pages 为 late final 缓存的同一批 widget 实例，Element update 恒等短路 ➔ 需要实时响应的状态由子页自身持有（本地状态/监听），勿依赖父级重建下传 (Ref: goodshare)

## 测试

CI 上清理类测试随机挂（本地恒绿，45过2挂） ➔ purgeDeleted 用 deleted_at < cutoff，retention=0 时 cutoff 与同毫秒删除值相等漏删残留污染下个测试 ➔ 时间戳范围清理用 <= 而非 <（或保证 cutoff 严格晚于删除时刻） (Ref: goodshare)

路径白名单测试想断言 NUL 字节拒绝写成 'a/b\0.txt'，analyzer 报 unnecessary_string_escapes 且断言意图落空（\0 被当字面 '0'，是合法 rel） ➔ Dart 字符串无 \0 转义 ➔ 特殊字节用 \xHH 显式转义；「非法输入应拒绝」的断言要先确认真的构造出了非法输入 (Ref: goodshare)

## ui/播放器

详情页退出后报 setState() called after dispose(): _AudioPlayerState ➔ just_audio 流订阅（position/duration/playerState）listen 后未存引用、dispose 未取消，Widget 移除后流仍回调 setState（部分回调连 mounted 都没判）➔ 流式回调一律三件套：订阅存引用 + 回调判 mounted + dispose 里 cancel；video_player 的 addListener 需对称 removeListener（现有 _VideoPlayerState 是正确范本） (Ref: goodshare)

## sync/db

PRAGMA sqlite_version 在 sqflite_common_ffi 返回空结果集，快照代码 .first 崩 Bad state ➔ ffi 实现对部分 PRAGMA 的返回形态与 Android sqflite 不一致（实证：sqlite_version 空、schema_version/user_version 正常） ➔ 跨实现的 DB 元信息读取优先用标准 SQL（SELECT sqlite_version()）；应用级 schema 版本读 user_version（openDatabase version: 维护），schema_version 是 SQLite 内部 DDL cookie 语义不同 (Ref: goodshare)
- [flutter/ui] 展开面板「顶栏整行不显示」：Scaffold resizeToAvoidBottomInset 已从 body 扣除键盘、NavigationBar 已独立于 body，浮层又手动 padding 扣一遍 keyboard+底栏，固定高度+底对齐面板比可用区高出这些量、从顶部溢出被 Stack 裁掉 ➔ body 内浮层严禁再手算 viewInsets/bottomNavigationBar（双重扣减），靠约束满幅撑开让框架定位；高度能不手算就不手算 (Ref: goodshare)
- [flutter/ui] 点开便利贴整个功能消失（release 整树不渲染、无报错提示）：home_shell 的 Positioned 仅给 bottom 锚点，Stack 只在上下边同时给出时才收紧高度约束 → 子树 max height 无界，展开态 Column+Expanded 触发 unbounded flex layout 异常整树渲染失败；analyze/数据层单测全绿拦不住（无 widget 测 pump 到展开态） ➔ Stack 底部覆盖层要么 Positioned 四边拉满（内部用 Align 给收合态兜松约束——紧约束下 Container 固定高会被 clamp 成整屏），要么显式给高；含 Expanded 的覆盖层必须有 pump 展开态的 widget 回归测试 (Ref: goodshare)
- [test] workspace_test 并发全量跑随机炸「listWorkspaces 按创建时间倒序」：createdAt 是毫秒时间戳，同毫秒连续创建打平，ORDER BY 并列时次序不稳定，严格 lessThan 断言随机失败（此前单跑靠时序运气全绿） ➔ 测试断言时间戳严格序时造数必须跨毫秒（delay 2ms）；并列打平在产品里属合法态，不为测试 flake 改数据层契约 (Ref: goodshare)

## [2026-09-30] 手势竞技场 cancel 会误伤展开态（便利贴面板坍缩）
- 现象：外层 GestureDetector 的 onVerticalDragCancel 无门控，点按面板内部按钮（保存/标题/粗体）时拖拽识别器竞技场落败触发 cancel，回调里 `_progress=0` 把已展开面板拽回收合态。
- 规则：外层手势容器（拖拽/滑动容器包住内部可点内容）的 onDragCancel/onDragEnd 等「终态回调」必须按当前稳定态门控——展开态下 cancel 应直接 return，只有收合拖动期才执行回弹逻辑。
- 定位法：最小复现优先（单测试内「展开→点按钮」两步即可复现，无需跨测试泄漏假设）+ 在各状态变更点打 DBG 日志锁定触发链。

## [2026-09-30] Material(color: transparent) ≠ 透传命中——transparent 颜色仍不透明地吸收命中测试
- 现象：全屏 overlay 用 `Material(color: Colors.transparent)` 包裹，下方列表点击/滑动全部失效；换成 `type: MaterialType.transparency` 立即恢复。
- 规则：需要「只挡自己绘制区域、透传其余命中」的覆盖层，必须用 `MaterialType.transparency`；`color: Colors.transparent` 只是画不出颜色，RenderMaterial 依旧在其整个边界内参与命中并拦截手势。凡 Stack+Positioned 拉满的全屏覆盖层（便签/悬浮球/sheet 容器）套 Material 前先过此条。
- 定位法：逐层二分最小复现（先整块替换复现 → 再拆 Material/Align/Container 各层对照），比读代码猜快得多。

## [2026-09-30] Scaffold 已消费 body 的 MediaQuery.padding——组件内避让状态栏须取 View 原始值
- 现象：Scaffold body 内的组件用 `MediaQuery.of(context).padding.top` 避让状态栏，实测拿到 0，顶部内容顶进状态栏。
- 规则：Scaffold 会把安全区 padding 消费进 body 布局，body 内子孙读到的 MediaQuery.padding.top 通常是 0；需要原始状态栏高度时用 `MediaQueryData.fromView(View.of(context)).padding.top`（或把避让交给 Scaffold/SafeArea，不要在 body 内手算）。
- 连带：全屏 overlay 内给「最大高度」手算时，若 overlay 经 Positioned 拉满，静止分支的 Container 必须显式给 height——省略会吃满整屏约束，让手算失效。
- 追加（2026-09-30 二连坑）：`MediaQuery.of().size.height` 是整屏高，Scaffold body 内还叠着 NavigationBar——body 内组件手算「最大高度」必须用 LayoutBuilder 的 constraints.maxHeight，用屏高会高出底栏高、底对齐布局把顶部顶出可视区（现象=头部消失，极易误判为跟随别的元素隐藏）。
- [真机验收] 「加载失败」疑云排错一小时：HTTP 200 且格式校验通过仍解码失败 ➔ 自造 PNG 夹具的手写生成器把 filter 字节按像素写（规范要求每行一个），解压流长度不符、任何解码器都拒 ➔ 自造二进制夹具必须先机器自校验到解码器级（zlib 解压对拍期望长度）；且 HTTP 200 只证明传输成功、不证明渲染成功 (Ref: goodshare)
