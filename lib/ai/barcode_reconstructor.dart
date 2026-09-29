import 'dart:io';

import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

import '../data/repository.dart';
import 'reconstructor.dart';
import 'ml_capability.dart';

/// 条码 / 二维码扫描（ML Kit Barcode Scanning，2026-09-29）：端侧、离线、极快、零误识别。
///
/// 仅**手动触发**（`task_action=scan_barcode`，与 OCR / 分类同口径：摄入不自动跑模型），
/// 产出写入 `facets['条码']`（结构化：[类型:值] 列表）。识别后**只标注不动作**
/// （URL 码不自动打开、Wi-Fi 码不自动连——打开 / 连接是链接条目 / 系统职责，不抢相册）。
///
/// 错误 / 空产出按 R1/R3 可观测：失败原因进 `note`。
class BarcodeReconstructor extends MlCapability {
  BarcodeReconstructor();

  @override
  String get id => Repository.taskScanBarcode;

  @override
  ExecutionMode get mode => ExecutionMode.backgroundQueue;

  @override
  Future<CapabilityReadiness> ensureReady() async => CapabilityReadiness.ready;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.itemType == 'image' && input.taskAction == Repository.taskScanBarcode;

  /// 执行：扫描图片中所有条码 / 二维码，返回 [类型:值] 列表（文件缺失时标记）。
  @override
  Future<BarcodeRaw> run(ReconstructInput input) async {
    final path = input.rawFilePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return BarcodeRaw(const [], fileMissing: true);
    }
    final scanner = BarcodeScanner();
    try {
      final inputImage = InputImage.fromFilePath(path);
      // 扫描通常毫秒级；极端机型可能挂起，超时兜底避免占住队列（与 OCR 同口径）。
      final barcodes = await scanner.processImage(inputImage)
          .timeout(const Duration(seconds: 20));
      final entries = <String>[];
      for (final b in barcodes) {
        final value = b.displayValue ?? b.rawValue;
        if (value == null || value.isEmpty) continue;
        entries.add('${b.format.name}:$value');
      }
      return BarcodeRaw(entries);
    } finally {
      await scanner.close();
    }
  }

  /// 后置归一化：原始条码 → 统一 [ReconstructResult]（facets / note 同口径）。
  @override
  ReconstructResult normalize(Object? raw, ReconstructInput input) {
    final r = raw as BarcodeRaw;
    final humanMd = input.rawContent ?? '';
    if (r.fileMissing) {
      return ReconstructResult(humanMd: humanMd, note: '图片文件缺失，无法扫描条码');
    }
    if (r.entries.isEmpty) {
      return ReconstructResult(humanMd: humanMd, note: '未识别到条码 / 二维码');
    }
    return ReconstructResult(
      humanMd: humanMd,
      facets: {'条码': r.entries},
      note: '已识别 ${r.entries.length} 个条码 / 二维码',
    );
  }
}

/// [run] 的原始输出：[类型:值] 列表（或标记文件缺失）。
class BarcodeRaw {
  const BarcodeRaw(this.entries, {this.fileMissing = false});

  final List<String> entries;
  final bool fileMissing;
}
