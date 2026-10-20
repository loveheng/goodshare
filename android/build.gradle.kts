allprojects {
    repositories {
        google()
        mavenCentral()
        // goodhub-mcp SDK（:plugin-core 传递引入 :contract 契约 AAR，AIDL 唯一物理副本）：
        // 解析顺序——① 本地离线分发件（免认证，同机开发最快；默认 /home/zzh/app/goodhub-mcp-sdk/dist/maven-repo，
        //    可用 GOODHUB_MCP_SDK_REPO 环境变量覆盖，如克隆 SDK 仓后指向其 dist/maven-repo）；
        //    ② mavenLocal()（若曾 `publishToMavenLocal` 到 ~/.m2/repository）；
        //    ③ GitHub Packages 公网坐标（需 read:packages 的令牌：优先 GH_PACKAGES_TOKEN，回退 GITHUB_TOKEN；
        //    公开包若支持匿名读取则可空 token 直连，跨仓则 GITHUB_TOKEN 默认无权限，须配 PAT Secret）。
        val sdkLocalRepo = System.getenv("GOODHUB_MCP_SDK_REPO")
            ?: "/home/zzh/app/goodhub-mcp-sdk/dist/maven-repo"
        maven { url = uri(sdkLocalRepo) }
        mavenLocal()
        maven {
            url = uri("https://maven.pkg.github.com/loveheng/goodhub-mcp-sdk")
            credentials {
                username = System.getenv("GITHUB_ACTOR") ?: "loveheng"
                password = System.getenv("GH_PACKAGES_TOKEN") ?: System.getenv("GITHUB_TOKEN") ?: ""
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
