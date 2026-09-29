# google_mlkit_text_recognition 插件代码引用了全部脚本识别器，
# 未引入脚本的类用 dontwarn 跳过（日 / 韩 / 天城文；中文已通过 GMS 依赖引入）
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
-dontwarn com.google.mlkit.vision.text.devanagari.**

# ML Kit 端侧 OCR（含中文 bundled 库）：release R8 会把反射 / 动态加载的识别器与
# 模型加载类误优化，导致 TextRecognizer.processImage 抛出 NPE（被业务层静默吞掉 → 无 OCR 文本）。
# 保留整个 mlkit 包及其 GMS 桥接包，禁用其成员被移除 / 重命名。
-keep class com.google.mlkit.** { *; }
-keep interface com.google.mlkit.** { *; }
# 部分 ML Kit 内部经 com.google.android.gms.dynamic / internal 桥接，一并保留以防运行期 NoClassDefFound
-keep class com.google.android.gms.** { *; }
-keep interface com.google.android.gms.** { *; }
-keep class com.google.android.gms.play-services-mlkit.** { *; }
-keep class com.google.android.gms.vision.** { *; }
# 保留注解 / 签名 / 内部类，避免 R8 移除被反射或 JNI 访问的成员
-keepattributes *Annotation*, Exceptions, Signature, InnerClasses, EnclosingMethod, RuntimeVisible*Annotations
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# WorkManager / Room：release R8 会误删 androidx.work 内 Room 反射生成的 WorkDatabase_Impl，
# 导致启动 "Failed to create an instance of androidx.work.impl.WorkDatabase" 崩溃。保留相关类。
-keep class androidx.work.** { *; }
-keep class androidx.room.** { *; }
-keep class * extends androidx.room.RoomDatabase { *; }
-dontwarn androidx.work.**
-dontwarn androidx.room.**
