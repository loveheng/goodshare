# google_mlkit_text_recognition 插件代码引用了全部脚本识别器，
# 未引入脚本的类用 dontwarn 跳过（日 / 韩 / 天城文；中文已通过 GMS 依赖引入）
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
