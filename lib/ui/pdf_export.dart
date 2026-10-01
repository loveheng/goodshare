import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/item.dart';

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

  static Future<String?> export(InboxItem item) async {
    final fontBytes = await rootBundle.load(
      'assets/fonts/DroidSansFallbackFull.ttf',
    );
    final font = pw.Font.ttf(fontBytes);
    final title = _titleOf(item);
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
          pw.Text(
            item.bodyText,
            style: pw.TextStyle(font: font, fontSize: _fontSizeBody),
          ),
          if (item.summaryMd != null && item.summaryMd!.trim().isNotEmpty) ...[
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
          if (item.tags.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Text(
              '标签：${item.tags.join('、')}',
              style: pw.TextStyle(font: font, fontSize: _fontSizeMeta, color: PdfColors.grey),
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
