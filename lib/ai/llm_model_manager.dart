import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'llm.dart';
import 'llm_model.dart';

/// 端侧 LLM 模型包下载管理（2026-09-28）：与 ASR `ModelManager` 同构但极简——
/// 单文件 `.litertlm`（自带 tokenizer），无断点续传（单文件整下）。
///
/// 落盘约定与 Android `LlmBridge.selectedModelFile` 对齐：
/// `documents/llm_models/{modelId}/model.litertlm`；选中档持久化 pref
/// `llm_selected_model`（Flutter 与原生各自读 SharedPreferences，键一致即通）。
class LlmModelManager extends ChangeNotifier {
  static const _prefSelected = 'llm_selected_model';

  final Dio _dio = Dio(BaseOptions(
    followRedirects: true,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 30),
  ));

  String? _selectedId;
  final Set<String> _ready = {};
  final Map<String, double> _progress = {};
  final Map<String, CancelToken> _cancels = {};

  String get selectedId => _selectedId ?? llmModels.first.id;

  LlmModel? get selected => llmModelById(selectedId);

  bool isReady(LlmModel m) => _ready.contains(m.id);

  double? progressOf(LlmModel m) => _progress[m.id];

  /// 本机可见模型（SoC 感知：NPU 专包仅对应机型可见，通用包恒可见）。
  Future<List<LlmModel>> visibleModels() async {
    final soc = await deviceSocModel();
    return [for (final m in llmModels) if (llmModelVisibleOnDevice(m, soc)) m];
  }

  /// 设备 SoC 型号（Android 原生回传；非 Android / 失败为 null）。
  Future<String?> deviceSocModel() => ChannelLlmEngine().socModel();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _selectedId = prefs.getString(_prefSelected) ?? llmModels.first.id;
    for (final m in llmModels) {
      final f = await _fileFor(m);
      if (await f.exists() && await f.length() > 0) {
        _ready.add(m.id);
      }
    }
    notifyListeners();
  }

  Future<File> _fileFor(LlmModel m) async {
    final base = await getApplicationDocumentsDirectory();
    return File(p.join(base.path, 'llm_models', m.id, 'model.litertlm'));
  }

  Future<void> select(String id) async {
    if (llmModelById(id) == null) return;
    _selectedId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSelected, id);
    notifyListeners();
  }

  /// 下载选中模型；进度经 [notifyListeners] 通知设置页。已就绪则幂等返回。
  Future<void> download(LlmModel m) async {
    if (isReady(m) || _progress.containsKey(m.id)) return;
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
      _ready.add(m.id);
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

  /// 清除已下载模型（腾空间；不撤历史产物）。
  Future<void> remove(LlmModel m) async {
    final file = await _fileFor(m);
    if (await file.exists()) await file.delete();
    _ready.remove(m.id);
    notifyListeners();
  }
}
