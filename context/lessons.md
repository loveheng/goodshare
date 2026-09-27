---
dev-loop: lessons
format: v1
epic: global
total-merged: 0
last-merge: none
---

# lessons

按模块归类的避坑规则正文（正文行禁用 `- [` 开头——该前缀专属底部追加区）

- [share_intake] 真机文本分享静默丢失（无报错、无入库） ➔ receive_sharing_intent 1.9.0 Android 端把 EXTRA_TEXT 写进 SharedMediaFile.path 而非 message，按字段名想当然读取落空 ➔ 第三方插件的数据形状必须读 pub 缓存里的平台实现源码取证，不能凭模型字段名/旧版本记忆假设；跨端行为差异用回归测试钉住真实 payload 形状 (Ref: goodshare)
- [构建] release 构建 R8 报 missing class（ML Kit 脚本识别器） ➔ google_mlkit_text_recognition 仅自带 latin 脚本依赖 ➔ 所需脚本（中文）在 app 级 build.gradle.kts 引入 GMS 依赖，未用脚本在 proguard-rules.pro dontwarn (Ref: goodshare)
- [Flutter] 父级 setState 不触发缓存子页重建（设置页 SegmentedButton 选中态不更新） ➔ HomeShell _pages 为 late final 缓存的同一批 widget 实例，Element update 恒等短路 ➔ 需要实时响应的状态由子页自身持有（本地状态/监听），勿依赖父级重建下传 (Ref: goodshare)
