# #9 同签名跨仓协调清单（goodshare ↔ goodhub）

> 域：goodhub-local-plugin · 编号 #9（改造清单 #9，风险/发布-联调签名门）
> 关联：`todos.md` #9 · `memory.md` 显式决策 2026-10-13「B2 签名权限已提前至 PoC 落地，两包须同签名同批」· eval §7.1 B2 / §8
> 状态（2026-10-14 回执后）：goodshare 声明侧已落；§3-1 goodhub `<uses-permission>` ✅已落；
> §3-2 现状对称（双方 release 现均走 debug key，同机构建即同源），正式 release 证书机制已给
> 口径、非阻塞 #10；§4 选**方案 1**；§5 双方均已承诺。#9 协调面已对齐，仅剩 §5 门禁待真机
> 窗口（第三批）跑通即关闭。

---

## 1. 为什么必须同签名（技术根因）

- goodshare `android/app/src/main/AndroidManifest.xml` 声明自定义权限
  `com.zzh.goodhub.permission.MCP_SERVER`，`protectionLevel="signature"`，并以其保护
  `McpBinderService`（`android:permission="com.zzh.goodhub.permission.MCP_SERVER"`）。
- Android `signature` 权限语义：**请求方**（goodhub，经 `<uses-permission>`）必须与
  **声明方**（goodshare，经 `<permission>`）由**同一证书**签名，否则 bind 直接抛
  `SecurityException`——无弹窗、无降级、零容错。
- 推论：
  1. 两 app 必须**同一发布证书**发布（eval §8「同发布者签名」前提）；
  2. 联调 debug 包也必须**同一 debug keystore**，否则联调即 `SecurityException`
     （memory 显式决策 2026-10-13）。

> 注：权限名虽带 `com.zzh.goodhub` 前缀，但**声明方是 goodshare**（本仓 Manifest）。
> 因此签名锚点 = goodshare 证书；goodhub 须匹配 goodshare。若未来改由 goodhub 声明，
> 锚点随之翻转——本清单以「goodshare 声明」为锁定决策（与已落代码一致）。

---

## 2. goodshare 侧（本仓可控）

- [x] **权限声明 + Service 保护**：`Manifest` 已加 `<permission ... protectionLevel="signature"/>`
      与 Service `android:permission`（#1/b5fc82f + eval B2 回填，已落地）。
- [ ] **release 签名配置补齐（缺口，仅阻塞"正式 release 出包"，不阻塞 #10）**：
      `android/app/build.gradle.kts:56` 的 `buildTypes.release` 现仍
      `signingConfig = signingConfigs.getByName("debug")`（与 goodhub `build.gradle.kts:41` 现状对称）。
      现状下两侧 release 同机构建即同源，**#10 debug 联调零影响**。仅当双方引入正式 release
      证书时须对齐（见 §3-2 口径 + §6）；彼时本仓补 `signingConfigs.create("release")` +
      `key.properties`（gitignore 读取）。该项作为"正式出包"前置，已与 #9 解耦单独立项。
- [ ] **确认 release 证书与 goodhub 同源**：见 §5 B.3 比对；不是"各自有 release 证书"即可，
      必须是**同一把**。
- [ ] **不在本仓加 `<uses-permission com.zzh.goodhub.permission.MCP_SERVER>`**：
      goodshare 是权限声明方/Service 提供方，请求权限的是 goodhub，本仓无需自请。

---

## 3. goodhub 侧（跨仓，回执归档 2026-10-14）

- [x] **Manifest 加 `<uses-permission android:name="com.zzh.goodhub.permission.MCP_SERVER"/>`**：
      ✅ 已落（`android/app/src/main/AndroidManifest.xml:16`，2026-10-13 B2 强耦合收尾轮）。
      goodhub 仅请求、未自声明 `<permission>`（声明方为 goodshare），符合 §1/§3 约定。
- [~] **release 包与 goodshare 同一把 release 证书签名（跨仓协调核心）**：
      ✅ 现状对称——goodhub `build.gradle.kts:41` release 走 `signingConfigs.debug`，
      goodshare 同样（`build.gradle.kts:56`），两侧 release 现均 debug key，同机构建即同源。
      正式 release 证书机制见 §8.2 回执口径；**非阻塞 #10**，作为 release 出包前置。
- [x] **联调 debug 包与 goodshare 联调包同一 debug keystore**：
      §4 已选**方案 1**（同机/同 CI `flutter build apk --debug` 复用默认 keystore，零侵入）。

---

## 4. 联调共享 debug keystore（跨机联调必做）

每台开发机默认 `~/.android/debug.keystore` 证书**随机生成、互不相同** → 跨机联调必
`SecurityException`。两种可行方案，择一：**⟹ 2026-10-14 双方选定方案 1（同机/同 CI 复用默认 keystore，零侵入，适用 #10）；
跨机常态化联调再升方案 2。**

- **方案 1（推荐，零代码侵入，临时联调）**：goodshare 与 goodhub 的联调 APK 都在
  **同一台构建机 / 同机 CI** 上 `flutter build apk --debug` → 自动复用同一默认
  `debug.keystore`。适合 #10 即时联调，无需改构建脚本。
- **方案 2（跨机稳定）**：两侧把 `signingConfigs.debug` 指向**同一份受控分发的 debug
  keystore**（密码/alias 约定一致：默认 `androiddebugkey` / `android`）。CI 与本地统一用该
  keystore，杜绝"我本地能跑、你那边 SecurityException"。
  - 实现：`build.gradle.kts` 的 `debug` signingConfig 改
    `storeFile = file("debug_signing/debug.keystore")`，`storePassword/keyPassword/keyAlias`
    从本地 `key.properties`（gitignore）读取；goodhub 侧镜像。
  - 受控：该 debug keystore 放安全分发点（非公开 git），仅联调用。
- [ ] 两侧联调包均装真机后，先单独验证 bind 不抛 `SecurityException`（轻量探针，见 §5 D.2），
      再进 #10 完整联调。

---

## 5. 签名一致性验证（#9 门禁）

> 双方（goodshare + goodhub）均承诺联调前各跑一次 D.1 + D.2（2026-10-14 回执对齐）。

- **D.1 证书指纹比对（确定性）**：抽取两 APK 证书，比对 subject / SHA-256 完全一致：
  ```bash
  keytool -printcert -jarfile goodshare.apk        # 看 SHA256 / Owner
  keytool -printcert -jarfile goodhub.apk          # 两侧同值即同源
  # 或
  apksigner verify --print-certs goodshare.apk | grep -i sha-256
  apksigner verify --print-certs goodhub.apk   | grep -i sha-256
  ```
- **D.2 真机"无 SecurityException"探针**：装好两包后，goodhub 发起一次
  `bindService(com.zzh.goodhub.action.MCP_SERVER)`，仅验证 `onServiceConnected` 命中（不跑工具）。
  命中 = 同签名生效；未命中看 logcat `SecurityException: ... not allowed to ...` = 签名不符。
- **D.3 门禁结论**：D.1 指纹一致 **且** D.2 探针通过 → #9 关闭，解锁 #10 真机联调。

---

## 6. 密钥管理 / 安全红线

- release keystore 属发布资产，**严禁入 git**；走 `key.properties`（gitignore）+ CI secret。
- 联调共享 debug keystore **仅用于联调，绝不可**当作 release 证书，且不得与 release 混用
  （一旦某 release 用了 debug key，后续无法换签、无法升级覆盖安装）。
- 若未来 goodhub 与 goodshare 由**不同发布主体**签名，则 `signature` 权限方案失效，须改
  `signatureOrSystem` 或换发现/鉴权机制（当前评估前提"同发布者签名"成立，故不采用）。

---

## 7. 门禁状态与依赖

- 当前（2026-10-14 回执后）：§3-1 ✅、§3-2 现状对称+口径已给、§4 选方案 1、§5 双方承诺。
  协调面已全部对齐；goodshare 本仓 release 签名配置仍 TODO（仅阻塞正式出包、不阻塞 #10）。
  #9 剩 §5 门禁实跑，受真机窗口（第三批）阻塞。
- 阻塞关系：#9 是 #10 真机联调的**硬前置**——未过 §5 门禁不得进 #10。
- 风险（启动要早）：发布证书对齐是跨仓协调，须尽早与 goodhub 约排期（memory 断点）。
- 下一步：① 等真机窗口（第三批：真机 + BYOK 云配置 + 第二真实服务）约好；② 双方跑 §5 门禁
  （D.1 指纹 + D.2 真机探针）；③ 通过即关闭 #9、进 #10 T5+T6 真机联调。
  （本仓 release 签名配置补齐列为"正式出包前置"，与 #9 解耦，单独立项。）

---

## 8. 双方回执归档（2026-10-14）

### 8.1 goodhub → goodshare 回执要点
- §3-1 `<uses-permission>` ✅ 已落（Manifest:16，2026-10-13 B2 强耦合收尾轮）；仅请求、未自声明。
- §3-2 release 证书：goodhub 现无独立 release 证书，release 走 debug key（build.gradle.kts:41）；
  对 #10 零影响；要求 goodshare 回执共享 release 证书机制。
- §4 选**方案 1**（默认 keystore，同机 `flutter build apk --debug` 复用，零侵入）。
- §5 承诺联调前各跑一次（D.1 指纹 + D.2 真机探针）。
- 排期：goodhub 随时就绪；#10 窗口取决于 goodshare 侧真机 + BYOK 云配置 + 第二真实服务（第三批）。

### 8.2 goodshare → goodhub 回执要点（已拟，待发，见下"回执草稿"）
- §3-1 收到确认；权限声明方为 goodshare，goodhub 仅请求，符合约定。
- §3-2 口径：现状两侧 release 均 debug-key（对称、同源无错配）；正式 release 证书待引入时双方
  指向**同一受控分发的 release keystore**（CI secret / 安全分发点，不入 git，同构 §4 方案 2），
  比对口径 = 两侧 APK `keytool -printcert -jarfile` SHA-256 一致；**非阻塞 #10**。
- §4 接受方案 1。
- §5 goodshare 侧同步承诺（D.1 + D.2）。
- 排期：与 goodhub 一致，等真机窗口约好即跑 §5 门禁、进 T5+T6。

### 8.3 #9 收口判定
- 协调面（§3 / §4 / §5 约定）**已全部对齐**；仅 §5 门禁实跑待真机窗口（第三批）执行。
- 真机窗口跑通 D.1 + D.2 → #9 关闭、解锁 #10。
