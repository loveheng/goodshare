---
dev-loop: lessons
format: v1
epic: global
total-merged: 3
last-merge: 2026-10-05
---

# lessons

按模块归类的避坑规则正文（正文行禁用 `- [` 开头——该前缀专属底部追加区）

## share_intake

真机文本分享静默丢失（无报错、无入库） ➔ receive_sharing_intent 1.9.0 Android 端把 EXTRA_TEXT 写进 SharedMediaFile.path 而非 message，按字段名想当然读取落空 ➔ 第三方插件的数据形状必须读 pub 缓存里的平台实现源码取证，不能凭模型字段名/旧版本记忆假设；跨端行为差异用回归测试钉住真实 payload 形状 (Ref: goodshare)

## 构建

release 构建 R8 报 missing class（ML Kit 脚本识别器） ➔ google_mlkit_text_recognition 仅自带 latin 脚本依赖 ➔ 所需脚本（中文）在 app 级 build.gradle.kts 引入 GMS 依赖，未用脚本在 proguard-rules.pro dontwarn (Ref: goodshare)

本机 flutter build 报 NDK LicenceNotAcceptedException（指向 /usr/lib/android-sdk） ➔ android/local.properties 的 sdk.dir 残留系统 SDK 路径而非 ~/android-sdk ➔ 构建类故障先查 local.properties 的 sdk.dir 与 ANDROID_HOME 指向，别先怀疑项目配置 (Ref: goodshare)

Flutter 构建注入类避坑规则（abiFilters 与 AGP splits 并存冲突、FlutterPlugin 强注入全 ABI 须 disable-abi-filtering、报错 Where 行号只是配置链第一现场）已固化为事实源 skill ➔ Ref: .agents/skills/goodshare-workflow/SKILL.md「ABI 约束」 (Ref: media-native)

## Flutter

父级 setState 不触发缓存子页重建（设置页 SegmentedButton 选中态不更新） ➔ HomeShell _pages 为 late final 缓存的同一批 widget 实例，Element update 恒等短路 ➔ 需要实时响应的状态由子页自身持有（本地状态/监听），勿依赖父级重建下传 (Ref: goodshare)

body 内浮层严禁手算避让与高度（三连坑归并）：①Scaffold 会把安全区 padding 消费进 body 布局，body 内子孙读到的 MediaQuery.padding.top 通常是 0——需要原始状态栏高度用 `MediaQueryData.fromView(View.of(context)).padding.top` 或交给 Scaffold/SafeArea；②resizeToAvoidBottomInset 已从 body 扣除键盘、NavigationBar 已独立于 body，浮层再手动扣一遍属双重扣减——靠约束满幅撑开让框架定位；③`MediaQuery.of().size.height` 是整屏高（body 内还叠 NavigationBar）——手算「最大高度」必须用 LayoutBuilder 的 constraints.maxHeight，用屏高会把头部顶出可视区（现象=头部消失，极易误判为元素隐藏）。连带：overlay 经 Positioned 拉满时，静止分支 Container 必须显式给 height，省略会吃满整屏约束让手算失效 (Ref: goodshare)

`testWidgets` 内 `await repo.add(...)` 永不返回，连 `Future.timeout` 都不触发（表象=测试挂死，常被误判成「页面有无限动画/pumpAndSettle 转圈」） ➔ testWidgets 运行在 **FakeAsync** 下：Timer 被假化，而 sqlite（sqflite ffi）的事务锁/查询依赖真实时钟与 isolate 消息 ➔ 排查手法：把每一步**同步写文件日志**（print 会被 reporter 缓冲，看不出断点），断点会精确落在第一个未完成的 await 上而不是落在 pumpAndSettle ➔ 修法分两级：用例侧真实异步一律 `tester.runAsync(() async { … })` 包裹；但「UI + 真实 DB」的页面级测试还会踩第二个坑——sqflite `txnSynchronized` 内部建 10s Timer，测试框架收尾报 *Pending timers* 且每次 rebuild（如 FutureBuilder 再查 `Repository.listTasks`）又造新 timer，`pump(Duration)` 推进也收敛不了 ➔ 硬结论：详情页这类 UI+真实库组合**不适用 widget test**，数据侧落普通 `test()`、UI 侧落纯组件 widget test（标签场景即有 `tag_editor_sheet_test.dart` 守组件、写路径有 `action_handler_test` 守数据） (Ref: goodshare)

点开便利贴整个功能消失（release 整树不渲染、无报错提示）：home_shell 的 Positioned 仅给 bottom 锚点，Stack 只在上下边同时给出时才收紧高度约束 → 子树 max height 无界，展开态 Column+Expanded 触发 unbounded flex layout 异常整树渲染失败；analyze/数据层单测全绿拦不住 ➔ Stack 底部覆盖层要么 Positioned 四边拉满（内部用 Align 给收合态兜松约束——紧约束下 Container 固定高会被 clamp 成整屏），要么显式给高；含 Expanded 的覆盖层必须有 pump 展开态的 widget 回归测试 (Ref: goodshare)

外层手势容器的「终态回调」必须按当前稳定态门控：外层 GestureDetector 的 onVerticalDragCancel 无门控时，点按面板内部按钮触发竞技场落败 cancel，把已展开面板拽回收合态（手势竞技场误伤展开态）——展开态下 cancel 直接 return，只有收合拖动期才执行回弹；定位用最小复现（单测试「展开→点按钮」两步）+ 状态变更点打 DBG 日志锁触发链 (Ref: goodshare)

需要「只挡自己绘制区域、透传其余命中」的全屏覆盖层，必须用 `MaterialType.transparency`：`Material(color: Colors.transparent)` 只是画不出颜色，RenderMaterial 依旧在整个边界内参与命中并拦截手势（下方列表点击/滑动全部失效）；凡 Stack+Positioned 拉满的覆盖层（便签/悬浮球/sheet 容器）套 Material 前先过此条 (Ref: goodshare)

详情页正文贴屏幕边缘无左右留白：sliver 虚拟化重构时 SliverPadding 写成无 sliver 子项的死代码（静默零渲染），留白从未生效 ➔ 包裹型 SliverPadding 改动后必须真机视觉确认；审查 sliver 组合先查子项存在 (Ref: goodshare)

## 测试

CI 上清理类测试随机挂（本地恒绿，45过2挂） ➔ purgeDeleted 用 deleted_at < cutoff，retention=0 时 cutoff 与同毫秒删除值相等漏删残留污染下个测试 ➔ 时间戳范围清理用 <= 而非 <（或保证 cutoff 严格晚于删除时刻） (Ref: goodshare)

路径白名单测试想断言 NUL 字节拒绝写成 'a/b\0.txt'，analyzer 报 unnecessary_string_escapes 且断言意图落空（\0 被当字面 '0'，是合法 rel） ➔ Dart 字符串无 \0 转义 ➔ 特殊字节用 \xHH 显式转义；「非法输入应拒绝」的断言要先确认真的构造出了非法输入 (Ref: goodshare)

并发全量跑随机炸「listWorkspaces 按创建时间倒序」：createdAt 是毫秒时间戳，同毫秒连续创建打平，ORDER BY 并列时次序不稳定，严格 lessThan 断言随机失败（单跑靠时序运气全绿） ➔ 测试断言时间戳严格序时造数必须跨毫秒（delay 2ms）；并列打平在产品里属合法态，不为测试 flake 改数据层契约 (Ref: goodshare)

自造二进制夹具必须先机器自校验到解码器级：「加载失败」疑云排错一小时，HTTP 200 且格式校验通过仍解码失败——手写 PNG 生成器把 filter 字节按像素写（规范要求每行一个），解压流长度不符、任何解码器都拒 ➔ 夹具用 zlib 解压对拍期望长度先自证；且 HTTP 200 只证明传输成功、不证明渲染成功 (Ref: goodshare)

widget 测试接入持久化后三坑：①跨用例泄漏（FFI 内存库全进程共享，上一用例 dispose flush 的草稿被下一用例恢复）；②fake async 区裸 await 真实 IO（sqflite FFI）永久死锁；③pkill 测试进程误伤 pub 解析+pdfium 下载重试，制造「挂起」假象 ➔ 持久化依赖注入（InMemoryDraftStore）让测试与 sqflite 彻底解耦，测试端清场 hack 能免则免；真实 IO 在 widget 测试必经 runAsync；超时杀进程前先查后台残留进程与网络重试循环 (Ref: goodshare)

## parser

往多分支解析正则中间插入新分支后，其后所有捕获分组号整体位移，handler 按旧号取组静默错位（链接被判成下划线） ➔ 分支与分组号必须同轮成对改；既有 serialize 往返测试兜住——解析类改动必须带往返幂等测试 (Ref: goodshare)

## 富文本

编辑态与详情阅读态行内格式显示不一致（编辑器有下划线、详情页没有），排查发现并非字体/样式问题 ➔ 编辑态走 span runs、阅读态走 rawContent 解析器，两条渲染路径上解析器不识 `<u>` 即静默丢格式 ➔ 凡「所见」要跨状态/跨页面一致的场景，格式必须走同一套「序列化↔解析↔渲染」同源链，任何旁路（AI 改写、纯文本透传、另写渲染器）都是格式丢失温床；视觉 bug 先查数据流（格式在哪一站丢了）再查渲染样式 (Ref: goodshare)

新行内标记（下划线）落地只测了「能解析出」单点，未防端到端丢格式 ➔ 格式系统的验收标准是 roundtrip 三层护栏：①codec 往返（parse 后 serialize 复原同串且幂等）②编辑组件播种（runs→toNoteSegments 落库串复原）③阅读态双渲染组件断言（TextDecoration 等真实样式在树） ➔ 以后加高亮/删除线等标记照 test/underline_roundtrip_test.dart 模式补三层用例 (Ref: goodshare)

下划线不一致三层测试全绿但用户真机仍复现，根因未定位即有「已修复」错觉 ➔ 测试全绿 ≠ 用户问题关闭——修不了根因时护栏测试仍值得写（防回归），但必须显式登记「未复现/待补复现路径」挂起，不能静默当已解决 (Ref: goodshare)

AI 回写无条件写 human_md=产出，而占位实现/超时兜底把产出填成 input.rawContent——落库即覆盖用户编辑过的正文，丢内容也丢行内样式（「编辑态有下划线、详情没有」的最强嫌疑） ➔ 产出与 raw_content 逐字符相同=「本次无新正文」→ 保留现值；被动降级回写保护 ≠ 主动重做覆盖，两者由「谁发起」分开（用户显式重新处理须先重置 human_md 再入队） (Ref: goodshare)

## ui/播放器

详情页退出后报 setState() called after dispose(): _AudioPlayerState ➔ just_audio 流订阅（position/duration/playerState）listen 后未存引用、dispose 未取消，Widget 移除后流仍回调 setState（部分回调连 mounted 都没判）➔ 流式回调一律三件套：订阅存引用 + 回调判 mounted + dispose 里 cancel；video_player 的 addListener 需对称 removeListener（现有 _VideoPlayerState 是正确范本） (Ref: goodshare)

## sync/db

PRAGMA sqlite_version 在 sqflite_common_ffi 返回空结果集，快照代码 .first 崩 Bad state ➔ ffi 实现对部分 PRAGMA 的返回形态与 Android sqflite 不一致（实证：sqlite_version 空、schema_version/user_version 正常） ➔ 跨实现的 DB 元信息读取优先用标准 SQL（SELECT sqlite_version()）；应用级 schema 版本读 user_version（openDatabase version: 维护），schema_version 是 SQLite 内部 DDL cookie 语义不同 (Ref: goodshare)

## ui/转盘

格式转盘行内置灰不生效：手势路径读 kDialCategories 常量表 disabled 位（恒 false）而非组件入参 inlineDisabled ➔ 静态数据表只放结构常量，随运行态变化的开关真值必须取自组件入参/状态；几何命中测试精确边界断言（恰 r=44/恰 -150°）经双精度 atan2/sqrt 往返必抖动 ➔ 边界语义用旁值双探针 (Ref: misc)

转盘反悔停留交互改造丢提交：三级选中后停留期内一打字即触发 keyPressed 收合，原实现把挂起中的选择作废——快节奏「选完立刻打字」流静默丢格式（真机实证「选了没效果」） ➔ 把「立即生效」改为「延迟生效」时，所有既有打断路径（打字即收/失焦收/宿主闭合）必须重新处置：打断应视为强确认（post-frame 先落地挂起选择再退场），而非作废；交互语义变更的影响面=全生命周期而非新增路径 (Ref: goodshare)
