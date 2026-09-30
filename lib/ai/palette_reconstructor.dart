import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../data/repository.dart';
import '../models/item.dart';
import 'reconstructor.dart';

/// V3 主色调提取（rich-text-component.md §6.1，2026-09-30）：
/// 摄入队列 Job 化——图片条目摄入即入队 [Repository.taskExtractPalette]，
/// 64px 降采样量化取主色，hex 落 `machine_json`（color.v1），图片加载前作
/// 占位底色（列表/详情消灭白闪）。**不在 build 路径同步算**（耗时路径 Job 化约束）。
///
/// 机器json 冲替安全性：image 条目的 machine_json 只有本 reconstructor 写
/// （OCR/分类走 humanMd/facets），applyAiResult 仅在产出非空时整替，无互踩。
class PaletteReconstructor implements AiReconstructor {
  const PaletteReconstructor();

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> handles(ReconstructInput input) async =>
      input.itemType == InboxItem.typeImage &&
      input.taskAction == Repository.taskExtractPalette;

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final path = input.rawFilePath;
    if (path == null || path.isEmpty || !File(path).existsSync()) {
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '主色提取未执行：图片文件不可访问',
      );
    }
    try {
      // size=64：按 64px 降采样解码后量化，控制耗时与内存（非整图全尺寸）
      final palette = await PaletteGenerator.fromImageProvider(
        FileImage(File(path)),
        size: const Size(64, 64),
      ).timeout(const Duration(seconds: 20));
      final color = palette.dominantColor?.color;
      if (color == null) {
        return ReconstructResult(
          humanMd: input.rawContent ?? '',
          note: '主色提取无产出（图片退化或纯透明）',
        );
      }
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        machineJson: {'schema': 'color.v1', 'hex': colorToHex(color)},
      );
    } catch (e) {
      // 超时/解码失败：不置死信，占位完成并带原因（降级不卡死口径）
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        note: '主色提取失败：$e',
      );
    }
  }
}

/// Color → `#rrggbb`（丢弃 alpha——占位底色恒不透明）。
String colorToHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// machine_json（color.v1）→ Color；非本 schema / 坏 JSON / 非法 hex 返回 null。
/// 容忍 6 位（#rrggbb）与 8 位（#aarrggbb）两种长度。
Color? colorFromMachineJson(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['schema'] != 'color.v1') return null;
  final hex = decoded['hex'];
  if (hex is! String) return null;
  final body = hex.replaceFirst('#', '');
  final value = int.tryParse(body, radix: 16);
  if (value == null) return null;
  return switch (body.length) {
    6 => Color(0xFF000000 | value),
    8 => Color(value),
    _ => null,
  };
}
