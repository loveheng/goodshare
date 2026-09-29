import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';

import '../data/repository.dart';
import 'reconstructor.dart';
import 'ml_capability.dart';

/// 文档扫描（ML Kit Document Scanner，2026-09-29）：**前台调起系统相机 UI**，
/// 不经队列、不写已有条目——扫描产出直接**新建条目**（每页一张图片，或整本 PDF）。
///
/// 与分类 / 条码 / 文本分析不同：它是相机流，AI（MCP/headless）无法调起相机，故
/// **没有 MCP 工具、不进 ReconstructorRegistry 的队列路由**（[handles] 仅作契约占位）。
/// UI 直接 `ensureReady()` + `reconstruct()` 拿到扫描结果再建条目。
///
/// 环境门控（GMS）：文档扫描是 GMS API、无法像 OCR 那样 bundled（OCR 教训是「bundled 后
/// 不要做 GMS 预检以免国内无 GMS 设备误关」，文档扫描则真依赖 GMS）。本实现**不做脆性的
/// `GoogleApiAvailability` 预检**（会重演 OCR 早期误关 bug），改为**运行时优雅降级**：
/// 点击才尝试 `scanDocument()`，无 GMS 抛 PlatformException → 归占位完成并明说原因
/// （与翻译层 Noop 同源，R1/R3 可观测）。若后续要「无 GMS 真隐藏入口」，可在 [ensureReady]
/// 接入原生 MethodChannel 查 `GoogleApiAvailability`——此处留钩子。
class DocumentScanCapability extends MlCapability {
  DocumentScanCapability();

  @override
  String get id => Repository.taskScanDocument;

  @override
  ExecutionMode get mode => ExecutionMode.foregroundUi;

  @override
  Future<CapabilityReadiness> ensureReady() async => CapabilityReadiness.ready;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.taskAction == Repository.taskScanDocument;

  /// 执行：调起系统文档扫描相机流（前台 UI，用户点完成/取消才返回）。
  /// 无 GMS / Play → 抛 PlatformException，捕获后降级（不静默、不崩）。
  @override
  Future<DocumentScanRaw> run(ReconstructInput input) async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: {DocumentFormat.jpeg, DocumentFormat.pdf},
      ),
    );
    try {
      // 相机流耗时不可预估（用户手动操作），放宽超时仅防极端挂起。
      final r = await scanner
          .scanDocument()
          .timeout(const Duration(seconds: 120));
      return DocumentScanRaw(images: r.images ?? const [], pdfUri: r.pdf?.uri);
    } on PlatformException catch (e) {
      // GMS / Play 缺失或设备不支持 → 优雅降级（原因进 note，UI 展示）。
      debugPrint('[DocScan] unavailable (GMS/Play missing?): $e');
      return DocumentScanRaw(gmsUnavailable: true);
    } finally {
      await scanner.close();
    }
  }

  /// 后置归一化：扫描结果 → 统一 [ReconstructResult]，扫描产出经 machine_json 透传 UI 建条目。
  @override
  ReconstructResult normalize(Object? raw, ReconstructInput input) {
    final r = raw as DocumentScanRaw;
    final humanMd = input.rawContent ?? '';
    if (r.gmsUnavailable) {
      return ReconstructResult(
        humanMd: humanMd,
        note: '文档扫描不可用：设备无 Google Play 服务（GMS），无法调起系统扫描',
      );
    }
    if (r.images.isEmpty && r.pdfUri == null) {
      return ReconstructResult(humanMd: humanMd, note: '未扫描到内容（已取消）');
    }
    return ReconstructResult(
      humanMd: humanMd,
      machineJson: {
        'document_scan': {'images': r.images, 'pdf': r.pdfUri},
      },
      note: '已扫描 ${r.images.length} 页图片'
          '${r.pdfUri != null ? '（含 PDF）' : ''}',
    );
  }
}

/// [run] 的原始输出：扫描到的图片路径 + 可选 PDF uri + GMS 不可用标记。
class DocumentScanRaw {
  const DocumentScanRaw({this.images = const [], this.pdfUri, this.gmsUnavailable = false});

  final List<String> images;
  final String? pdfUri;
  final bool gmsUnavailable;
}
