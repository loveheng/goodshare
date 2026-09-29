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
