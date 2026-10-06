import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/item.dart';
import 'share_scope_sheet.dart' show ShareScope;

/// 详情条目导出 PDF（ui-spec §4.3 两区改版：公共区「导出 PDF」）。
///
/// 中文字体内嵌 `assets/fonts/DroidSansFallbackFull.ttf`（Apache 2.0，可再
/// 分发）——pdf 包内置字体不含 CJK，不内嵌则中文全是空白。
/// 产物落系统临时目录，返回文件路径供调用方接分享（share_plus XFile）。
class ItemPdfExporter {
  ItemPdfExporter._();

  /// PDF 排版字号（文档级常量，非 UI textTheme 语义——pdf 包渲染与
  /// Flutter textTheme 无关，arch-guard R7 白名单外以常量消除字面量）。
  static const double _fontSizeTitle = 20;
  static const double _fontSizeMeta = 10;
  static const double _fontSizeBody = 12;
  static const double _fontSizeHeading = 14;

  /// 标题取 AI 重构标题，缺省回落正文首行（InboxItem 无独立 title 字段）。
  static String _titleOf(InboxItem item) {
    final t = item.humanTitle?.trim();
    if (t != null && t.isNotEmpty) return t;
    final body = item.bodyText.trim();
    if (body.isEmpty) return '拾贝条目';
    final firstLine = body.split('\n').first.trim();
    return firstLine.isEmpty ? '拾贝条目' : firstLine;
  }

  /// [scope] 分享范围勾选（share_scope_sheet.dart）：四个开关在此**真实裁剪**
  /// 产物内容（2026-10-05 修：此前 scope 拿到即弃，勾选零作用且违反
  /// 「灵感区默认关」隐私红线注释）。标签随「AI 摘要」开关联动（勾选单
  /// 无独立项，同属 AI 产出区）；[blockAppendixText] 为调用方从块通道
  /// 装载的 OCR/转写文本（勾选「识别与转写文本」时传入）。
  static Future<String?> export(
    InboxItem item, {
    ShareScope scope = const ShareScope(),
    String? blockAppendixText,
  }) async {
    final fontBytes = await rootBundle.load(
      'assets/fonts/DroidSansFallbackFull.ttf',
    );
    final font = pw.Font.ttf(fontBytes);
    final title = _titleOf(item);
    final inspiration = item.inspirationMd?.trim() ?? '';
    final appendix = blockAppendixText?.trim() ?? '';
    final doc = pw.Document();
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(48, 56, 48, 56),
        build: (ctx) => [
          pw.Text(
            title,
            style: pw.TextStyle(font: font, fontSize: _fontSizeTitle),
          ),
          pw.SizedBox(height: 12),
          pw.Text(
            '${_typeLabel(item.itemType)} · ${_fmtDate(item.createdAt)}',
            style: pw.TextStyle(font: font, fontSize: _fontSizeMeta, color: PdfColors.grey),
          ),
          pw.Divider(height: 24),
          if (scope.includeBody)
            pw.Text(
              item.bodyText,
              style: pw.TextStyle(font: font, fontSize: _fontSizeBody),
            ),
          if (scope.includeSummary &&
              item.summaryMd != null &&
              item.summaryMd!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text(
              '摘要',
              style: pw.TextStyle(font: font, fontSize: _fontSizeHeading),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              item.summaryMd!,
              style: pw.TextStyle(font: font, fontSize: _fontSizeBody),
            ),
          ],
          if (scope.includeSummary && item.tags.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(
              '标签：${item.tags.join('、')}',
              style: pw.TextStyle(font: font, fontSize: _fontSizeMeta, color: PdfColors.grey),
            ),
          ],
          if (scope.includeInspiration && inspiration.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text(
              '灵感',
              style: pw.TextStyle(font: font, fontSize: _fontSizeHeading),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              inspiration,
              style: pw.TextStyle(font: font, fontSize: _fontSizeBody),
            ),
          ],
          if (scope.includeBlockAppendix && appendix.isNotEmpty) ...[
            pw.SizedBox(height: 16),
            pw.Text(
              '识别与转写文本',
              style: pw.TextStyle(font: font, fontSize: _fontSizeHeading),
            ),
            pw.SizedBox(height: 6),
            pw.Text(
              appendix,
              style: pw.TextStyle(font: font, fontSize: _fontSizeBody),
            ),
          ],
        ],
      ),
    );
    final dir = await Directory.systemTemp.createTemp('goodshare_pdf');
    final name = _safeName(title);
    final file = File('${dir.path}/$name.pdf');
    await file.writeAsBytes(await doc.save());
    return file.path;
  }

  static String _typeLabel(String type) => switch (type) {
        InboxItem.typeNote => '便签',
        InboxItem.typeImage => '图片',
        InboxItem.typeAudio => '音频',
        InboxItem.typeVideo => '视频',
        InboxItem.typeUrl => '链接',
        InboxItem.typeDocument => '文档',
        InboxItem.typeChatlog => '会话',
        _ => type,
      };

  static String _fmtDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$m-$day';
  }

  /// 文件名安全化：路径分隔符与非法字符换下划线，限长防文件名过长。
  static String _safeName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
  }
}
