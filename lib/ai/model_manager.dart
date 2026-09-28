import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'asr_model.dart';

/// 单个模型文件的下载阶段。
enum DownloadPhase {
  idle, // 未开始 / 已清除
  downloading, // 下载中
  ready, // 已就绪（全部文件齐备且校验通过）
  error,
}

/// 一个模型的整体下载状态（进度为整模型 0..1）。
@immutable
class DownloadState {
  const DownloadState({required this.phase, this.progress = 0, this.error});

  final DownloadPhase phase;
  final double progress;
  final String? error;

  bool get isReady => phase == DownloadPhase.ready;
  bool get isDownloading => phase == DownloadPhase.downloading;

  DownloadState copyWith({DownloadPhase? phase, double? progress, String? error, bool clearError = false}) =>
      DownloadState(
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
        error: clearError ? null : (error ?? this.error),
      );
}

/// ASR 模型按需下载与缓存管理（2026-09-28）：
/// - 缓存目录 `docs/asr_models/{modelId}/`（与附件 `docs/shares` 同层）；
/// - 逐文件断点续传：dio `FileAccessMode.append` + `Range` header，落 `.part` 后校验大小再改名；
/// - 已下载 = 全部文件存在且大小与目录一致（换源/校验失败可自愈）；
/// - 选中档位持久化（SharedPreferences），设置页据此渲染。
class ModelManager extends ChangeNotifier {
  static const _prefSelected = 'asr_selected_model';

  final Dio _dio = Dio(BaseOptions(
    followRedirects: true,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 5),
  ));

  String? _selectedId;
  final Map<String, DownloadState> _state = {};
  final Map<String, CancelToken> _cancels = {};

  String get selectedId => _selectedId ?? asrModels.first.id;

  AsrModel get selectedModel => asrModelById(selectedId) ?? asrModels.first;

  DownloadState stateOf(AsrModel m) =>
      _state[m.id] ?? const DownloadState(phase: DownloadPhase.idle);

  /// 从持久化恢复选中档位，并探测已下载状态。
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefSelected);
    _selectedId = asrModelById(saved)?.id ?? asrModels.first.id;
    for (final m in asrModels) {
      if (await isDownloaded(m)) {
        _state[m.id] = const DownloadState(phase: DownloadPhase.ready, progress: 1);
      }
    }
    notifyListeners();
  }

  /// 模型缓存目录。
  Future<Directory> dirFor(AsrModel m) async {
    final base = await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, 'asr_models', m.id));
  }

  /// 是否已下载（全部文件存在且大小匹配）。
  Future<bool> isDownloaded(AsrModel m) async {
    final dir = await dirFor(m);
    if (!dir.existsSync()) return false;
    for (final e in m.files.entries) {
      final f = File(p.join(dir.path, e.key));
      if (!f.existsSync()) return false;
      if (f.lengthSync() != e.value.size) return false;
    }
    return true;
  }

  Future<void> selectModel(String id) async {
    final m = asrModelById(id);
    if (m == null) return;
    _selectedId = m.id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSelected, m.id);
    notifyListeners();
  }

  /// 下载模型（已就绪则直接返回）。可中断；中断后可再次 [download] 续传。
  Future<void> download(AsrModel m) async {
    if (await isDownloaded(m)) {
      _state[m.id] = const DownloadState(phase: DownloadPhase.ready, progress: 1);
      notifyListeners();
      return;
    }
    if (stateOf(m).isDownloading) return; // 已在下载

    final cancel = CancelToken();
    _cancels[m.id] = cancel;
    _update(m.id, (s) => s.copyWith(phase: DownloadPhase.downloading, progress: 0, clearError: true));

    try {
      final dir = await dirFor(m);
      dir.createSync(recursive: true);
      final int total = m.totalBytes;
      int done = 0;

      for (final e in m.files.entries) {
        final finalFile = File(p.join(dir.path, e.key));
        final part = File(p.join(dir.path, '${e.key}.part'));

        // 已完成且校验通过的文件跳过
        if (finalFile.existsSync() && finalFile.lengthSync() == e.value.size) {
          done += e.value.size;
          continue;
        }

        // 断点：.part 已下载部分（超出的损坏部分丢弃重来）
        int existing = 0;
        if (part.existsSync()) {
          existing = part.lengthSync();
          if (existing >= e.value.size) {
            part.deleteSync();
            existing = 0;
          }
        }

        await _dio.download(
          m.urlFor(e.key),
          part.path,
          cancelToken: cancel,
          deleteOnError: false, // 保留 .part 以便续传
          fileAccessMode: FileAccessMode.append,
          options: Options(
            headers: existing > 0 ? {'Range': 'bytes=$existing-'} : null,
          ),
          onReceiveProgress: (recv, _) {
            _update(m.id, (s) => s.copyWith(progress: (done + existing + recv) / total));
          },
        );

        // 校验：Range 未生效导致翻倍 / 截断时丢弃重来
        if (part.lengthSync() != e.value.size) {
          part.deleteSync();
          continue;
        }
        if (finalFile.existsSync()) finalFile.deleteSync();
        part.renameSync(finalFile.path);
        done += e.value.size;
        _update(m.id, (s) => s.copyWith(progress: done / total));
      }

      _state[m.id] = const DownloadState(phase: DownloadPhase.ready, progress: 1);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _update(m.id, (s) => s.copyWith(phase: DownloadPhase.idle, clearError: true));
      } else {
        _update(m.id, (s) => s.copyWith(phase: DownloadPhase.error, error: e.message ?? 'download failed'));
      }
    } catch (e) {
      _update(m.id, (s) => s.copyWith(phase: DownloadPhase.error, error: '$e'));
    } finally {
      _cancels.remove(m.id);
      notifyListeners();
    }
  }

  Future<void> cancelDownload(String id) async {
    final c = _cancels[id];
    if (c == null) return;
    c.cancel('user cancelled');
    _update(id, (s) => s.copyWith(phase: DownloadPhase.idle, clearError: true));
  }

  /// 清除某模型缓存（先中断下载）。
  Future<void> clearCache(AsrModel m) async {
    await cancelDownload(m.id);
    final dir = await dirFor(m);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (e) {
        debugPrint('[ModelManager] clearCache failed: $e');
      }
    }
    _update(m.id, (s) => const DownloadState(phase: DownloadPhase.idle, progress: 0));
  }

  void _update(String id, DownloadState Function(DownloadState s) f) {
    _state[id] = f(stateOf(asrModelById(id) ?? asrModels.first));
    notifyListeners();
  }
}
