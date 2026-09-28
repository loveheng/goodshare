import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../update/remote_config_store.dart';
import 'llm.dart';
import 'llm_model.dart';

/// 端侧 LLM 模型包下载管理（2026-09-28）：与 ASR `ModelManager` 同构但极简——
/// 单文件 `.litertlm`（自带 tokenizer），无断点续传（单文件整下）。
///
/// 落盘约定与 Android `LlmBridge.selectedModelFile` 对齐：
/// `documents/llm_models/{modelId}/model.litertlm`；选中档持久化 pref
/// `llm_selected_model`（Flutter 与原生各自读 SharedPreferences，键一致即通）。
/// 本地模型文件的版本比对结论。
enum _DiskState {
  absent, // 无文件
  ready, // 与 manifest 同版本（或存量无 meta，兼容放行）
  stale, // 有文件但 size 与 manifest 不一致（同 id 换了文件/量化）
}

class LlmModelManager extends ChangeNotifier {
  static const _prefSelected = 'llm_selected_model';

  /// 选择语义（2026-09-29「名字坐标」拍板）：
  /// - 显式选过：选中状态持久 **id+name**，目录更新后按 id→名字对位跟随同名模型
  ///   （id 换了也能跟住；同 id 换文件走 stale 提示，两条路径互不干扰）；
  /// - 从未显式选过：**自动跟随目录首条（发布者排序即最新记录）**，并同步原生 pref。
  /// 用户从不直接感知 id——名字才是用户与云端之间的坐标。
  static const _prefSelectedName = 'llm_selected_model_name';
  static const _prefExplicit = 'llm_selected_explicit';

  LlmModelManager({this._manifestUrl});

  /// manifest 地址取值器（null/空 = 不拉远端，恒用内置目录）。
  /// 接线：RemoteConfigStore.flags['llmManifestUrl']（检查更新后热更下发）。
  final String? Function()? _manifestUrl;

  final Dio _dio = Dio(BaseOptions(
    followRedirects: true,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
  ));

  String? _selectedId;
  bool _explicit = false; // 用户是否显式选过模型（false = 跟随目录首条 = 最新记录）
  final Set<String> _ready = {};
  final Set<String> _stale = {};
  final Map<String, double> _progress = {};
  final Map<String, CancelToken> _cancels = {};

  /// 当前生效目录：远端 manifest（last-good 缓存）> 内置默认。
  /// 本地缓存文件不存在时为 null，`catalog` 落回 [llmModels]。
  List<LlmModel> _catalog = llmModels;

  /// 本机残留条目（manifest 已移除、设备上仍有已下载文件）——叠加展示拍板
  /// （2026-09-29）：新模型与本机已下载模型同列表呈现，孤儿照常可用不隐藏。
  List<LlmModel> _orphans = const [];

  /// 当前生效的模型目录（设置页渲染与可见性过滤的数据源）＝ manifest 目录 + 本机残留。
  List<LlmModel> get catalog => [..._catalog, ..._orphans];

  String get selectedId => _selectedId ?? _catalog.first.id;

  LlmModel? get selected => modelById(selectedId);

  bool isReady(LlmModel m) => _ready.contains(m.id);

  /// 已下载但与当前 manifest 不同版本（同 id 换文件/换量化）——**仅信息性提示**
  /// （2026-09-29 用户拍板：旧模型用得好好的不能不让用）：就绪判定不受影响，
  /// 设置页显示「云端有新版本可更新」，更新与否由用户自选。
  bool isStale(LlmModel m) => _stale.contains(m.id);

  double? progressOf(LlmModel m) => _progress[m.id];

  /// 本机可见模型（SoC 感知：NPU 专包仅对应机型可见，通用包恒可见；残留条目恒可见）。
  Future<List<LlmModel>> visibleModels() async {
    final soc = await deviceSocModel();
    return [
      for (final m in catalog)
        if (m.localOnly || llmModelVisibleOnDevice(m, soc)) m
    ];
  }

  /// 设备 SoC 型号（Android 原生回传；非 Android / 失败为 null）。
  Future<String?> deviceSocModel() => ChannelLlmEngine().socModel();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _explicit = prefs.getBool(_prefExplicit) ?? false;
    await _loadCachedCatalog();
    await _syncOrphans();
    await _realignSelection(prefs);
    _syncReadyFlags();
    notifyListeners();
    // 远端刷新异步跑：失败静默留 last-good，不打断首帧
    unawaited(refreshCatalog());
  }

  /// 名字坐标对位：id 精确命中 → 名字命中（manifest 改 id 时的迁移路径）。
  LlmModel? _byName(String? name) {
    if (name == null || name.isEmpty) return null;
    for (final m in catalog) {
      if (m.name == name) return m;
    }
    return null;
  }

  /// 选择重对齐（load / refreshCatalog 后调用）——「名字坐标」语义：
  /// - 显式选过：id 精确 → 名字对位 → 兜底目录首条；
  /// - 未显式选过：**自动跟随目录首条（最新记录）**，与旧目录同名档自然解绑。
  /// 两条路径都持久化 id+name，保证原生桥（读 flutter.llm_selected_model）与 Dart 同步。
  Future<void> _realignSelection(SharedPreferences prefs) async {
    LlmModel? m;
    if (_explicit) {
      m = modelById(prefs.getString(_prefSelected)) ??
          _byName(prefs.getString(_prefSelectedName));
    }
    m ??= _catalog.first;
    await _persistSelection(prefs, m);
  }

  Future<void> _persistSelection(SharedPreferences prefs, LlmModel m) async {
    _selectedId = m.id;
    await prefs.setString(_prefSelected, m.id);
    await prefs.setString(_prefSelectedName, m.name);
  }

  /// 扫盘合成残留条目（叠加展示拍板）：documents/llm_models/ 下有 model.litertlm
  /// 但不在当前目录的 id → 合成 [LlmModel.localOnly] 条目，与目录条目同列表呈现，
  /// 照常可用（旧文件引擎照跑），仅提示「云端已移除」；用户可手动删除腾空间。
  Future<void> _syncOrphans() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final root = Directory(p.join(base.path, 'llm_models'));
      if (!await root.exists()) {
        _orphans = const [];
        return;
      }
      final known = _catalog.map((m) => m.id).toSet();
      final found = <LlmModel>[];
      await for (final d in root.list()) {
        if (d is! Directory) continue;
        final id = p.basename(d.path);
        if (known.contains(id)) continue;
        final f = File(p.join(d.path, 'model.litertlm'));
        if (!await f.exists() || await f.length() <= 0) continue;
        found.add(LlmModel(
          id: id,
          name: id,
          desc: '云端目录已移除，本机保留可继续使用',
          file: 'model.litertlm',
          sizeBytes: await f.length(),
          localOnly: true,
        ));
      }
      _orphans = found;
    } catch (e) {
      // DEGRADE: 扫盘失败只影响叠加展示，不影响目录与下载；留日志不中断。
      debugPrint('[LlmModelManager] syncOrphans failed: $e');
    }
  }

  /// last-good 目录缓存：`documents/llm_manifest.json`。
  /// 损坏/缺失时保持内置目录（远端配置是外部输入，不能让它毁掉本地状态）。
  Future<void> _loadCachedCatalog() async {
    try {
      final f = await _cacheManifestFile();
      if (!await f.exists()) return;
      final parsed = llmModelsFromJson(jsonDecode(await f.readAsString()));
      if (parsed.isNotEmpty) _catalog = parsed;
    } catch (_) {
      // 缓存损坏 → 落回内置目录，等下次 refreshCatalog 覆盖
    }
  }

  Future<File> _cacheManifestFile() async {
    final base = await getApplicationDocumentsDirectory();
    return File(p.join(base.path, 'llm_manifest.json'));
  }

  /// 拉取远端 manifest 并替换目录（成功才写 last-good，全失败保持现状）。
  ///
  /// URL 来源（优先级）：构造参数 > RemoteConfigStore.flags['llmManifestUrl']。
  /// 供「检查更新成功后」与设置页下拉刷新调用；返回是否替换成功。
  Future<bool> refreshCatalog() async {
    final url = _manifestUrl?.call() ??
        RemoteConfigStore.instance.current.flags['llmManifestUrl'] as String?;
    if (url == null || url.isEmpty) return false;
    try {
      final res = await _dio.get<String>(url);
      final parsed = llmModelsFromJson(
        jsonDecode(res.data ?? '') as Object?,
      );
      // 空目录视为无效 manifest：可能是 CDN 半程/被劫持，绝不覆盖可用目录
      if (parsed.isEmpty) return false;
      _catalog = parsed;
      // 目录替换后重扫：被移除的条目转为「本机保留」，新条目不再算孤儿
      await _syncOrphans();
      final f = await _cacheManifestFile();
      await f.writeAsString(res.data ?? '', flush: true);
      // 目录可能已变：就绪标记与选中项都要对新目录重对齐（名字坐标语义：
      // 显式选过按 id→名对位跟随，未选过自动跟随新目录首条=最新记录）
      _syncReadyFlags();
      final prefs = await SharedPreferences.getInstance();
      await _realignSelection(prefs);
      notifyListeners();
      return true;
    } catch (e) {
      // DEGRADE: 拉取失败静默留 last-good（内置兜底），不打断用户；至少留日志。
      debugPrint('[LlmModelManager] refreshCatalog failed: $e');
      return false;
    }
  }

  /// 按 id 在**合并目录**（manifest + 本机残留）里找模型——叠加展示拍板：
  /// 残留条目照常可用，选中/下载/删除与目录条目同一套逻辑。
  LlmModel? modelById(String? id) {
    if (id == null) return null;
    for (final m in catalog) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 就绪探测按当前目录重跑（manifest 替换后旧标记可能失效）。
  /// **文件存在即可用**（2026-09-29 用户拍板：旧模型照常跑，云端更新不强禁）；
  /// stale 只作「云端有新版本」的提示标记，绝不阻塞就绪。
  Future<void> _syncReadyFlags() async {
    final ready = <String>{};
    final stale = <String>{};
    for (final m in _catalog) {
      final state = await _diskState(m);
      if (state == _DiskState.absent) continue;
      ready.add(m.id);
      if (state == _DiskState.stale) stale.add(m.id);
    }
    _ready
      ..clear()
      ..addAll(ready);
    _stale
      ..clear()
      ..addAll(stale);
    // 残留条目（扫盘时已确认文件存在）直接就绪：叠加展示拍板——照常可用
    _ready.addAll(_orphans.map((m) => m.id));
  }

  /// 本地文件与 manifest 条目的版本比对。
  ///
  /// 下载完成时落 `meta.json`（file/size/url 快照）；比对规则：
  /// - meta 存在 → 严格比对 size（manifest 换文件/换量化必改 size，改了即 stale）；
  /// - meta 缺失 → 旧版本 app 下载的存量，按 ready 处理；
  /// - stale **仅提示不阻塞**——旧文件对推理引擎完全可用，更新与否用户自选。
  Future<_DiskState> _diskState(LlmModel m) async {
    final f = await _fileFor(m);
    if (!await f.exists() || await f.length() <= 0) return _DiskState.absent;
    final meta = File(p.join(f.parent.path, 'meta.json'));
    if (!await meta.exists()) return _DiskState.ready; // 存量兼容
    try {
      final j = jsonDecode(await meta.readAsString()) as Map;
      return j['size'] == m.sizeBytes ? _DiskState.ready : _DiskState.stale;
    } catch (_) {
      // meta 损坏不阻塞（文件本身可用），按就绪处理
      return _DiskState.ready;
    }
  }

  Future<File> _fileFor(LlmModel m) async {
    final base = await getApplicationDocumentsDirectory();
    return File(p.join(base.path, 'llm_models', m.id, 'model.litertlm'));
  }

  Future<void> select(String id) async {
    final m = modelById(id);
    if (m == null) return;
    _explicit = true; // 显式选择后即脱离「自动跟随最新」，改按名字坐标跟随
    final prefs = await SharedPreferences.getInstance();
    await _persistSelection(prefs, m);
    await prefs.setBool(_prefExplicit, true);
    notifyListeners();
  }

  /// 下载选中模型；进度经 [notifyListeners] 通知设置页。已就绪则幂等返回；
  /// **stale（云端有新版本）不跳过**——允许更新到新文件（更新前后旧文件都可用）。
  Future<void> download(LlmModel m) async {
    if ((isReady(m) && !isStale(m)) || _progress.containsKey(m.id)) return;
    final file = await _fileFor(m);
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    _progress[m.id] = 0;
    notifyListeners();
    try {
      await _dio.download(
        m.urlFor(llmModelBase),
        part.path,
        onReceiveProgress: (c, t) {
          if (t > 0) {
            _progress[m.id] = c / t;
            notifyListeners();
          }
        },
        cancelToken: _cancels[m.id],
      );
      await part.rename(file.path);
      // 落版本快照：此后 manifest 同 id 换文件（size 变化）即可被 _diskState 识别为 stale
      await File(p.join(file.parent.path, 'meta.json')).writeAsString(
        jsonEncode({'id': m.id, 'file': m.file, 'size': m.sizeBytes, 'ts': DateTime.now().millisecondsSinceEpoch}),
        flush: true,
      );
      _ready.add(m.id);
      _stale.remove(m.id);
    } on DioException catch (e) {
      // gated 仓库（Gemma 系，需在 HuggingFace 网页接受许可条款）经 hf-mirror 会 403/401——
      // 必须给出可行动的原因，不让用户对着一个状态码猜（R1：错误要被感知且明说）。
      final code = e.response?.statusCode;
      if (code == 403 || code == 401) {
        throw Exception('该模型在 gated 仓库（需先在 huggingface.co 模型页登录并接受 Gemma 条款），'
            '直连与镜像都无法下载；二阶段将经自托管 R2 中转');
      }
      rethrow;
    } catch (e) {
      // DEGRADE: 下载失败属用户可重试动作，状态复位即可；不静默吞——设置页展示错误。
      debugPrint('[LlmModelManager] download failed (${m.id}): $e');
      rethrow;
    } finally {
      _progress.remove(m.id);
      _cancels.remove(m.id);
      notifyListeners();
    }
  }

  /// 清除已下载模型（腾空间；不撤历史产物）。删除孤儿条目后重扫，列表即时收敛。
  Future<void> remove(LlmModel m) async {
    final file = await _fileFor(m);
    if (await file.exists()) await file.delete();
    _ready.remove(m.id);
    _stale.remove(m.id);
    if (m.localOnly) await _syncOrphans();
    notifyListeners();
  }
}
