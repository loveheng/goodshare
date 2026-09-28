plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zzh.goodshare"
    // 插件 receive_sharing_intent 1.9.0 要求 compileSdk ≥ 37（高于 flutter 默认 36）
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zzh.goodshare"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // 固定 34：targetSdk 35+ 时 dataSync 前台服务受 6h/24h 限制，MCP 常驻服务不可接受；
        // 本 app 侧载分发，无商店 targetSdk 硬约束。
        targetSdk = 34
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    // ML Kit 中文脚本识别器：google_mlkit_text_recognition 插件仅自带 latin 脚本依赖（bundled
    // 通用库 com.google.mlkit:text-recognition:16.0.1），其余脚本需 app 侧手动引入。
    // 国内适配（2026-09-28 决策）：切 bundled 中文库 com.google.mlkit:*——模型打进 APK，
    // 离线可用，不依赖 GMS/Play 动态下载。注意：com.google.android.gms:play-services-mlkit-*
    // 是 unbundled 变体（模型经 Play 下载），国内不可用，勿用。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    // 端侧 LLM 运行时（2026-09-28，设计见 docs/design/on-device-llm.md）：
    // LiteRT-LM 纯 Kotlin 引擎（Maven Central，无 NDK/CMake），跑 .litertlm 模型包。
    // 坐标经 AndroLLM 实际工程核实（2026-09-29）：artifact 为 litertlm-android，
    // 非 litert-lm（后者在 Maven Central 不存在，构建期即解析失败）。
    implementation("com.google.ai.edge.litertlm:litertlm-android:0.16.0")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
