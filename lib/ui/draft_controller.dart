import 'dart:async';

import 'package:flutter/material.dart';

import '../models/draft_store.dart';

/// 草稿输入控制器：包装 [TextEditingController]，输入时 800ms 防抖落盘；
/// 退后台等场景调用 [flush] 立即强制落盘（绕过防抖），防止最后几个字符丢失。
///
/// 生命周期联动由使用方订阅 [AppLifecycleManager.onBackgrounded] 后调用 [flush]，
/// 不可在本类内自行订阅（避免与页面生命周期耦合）。
class DraftController {
  DraftController({
    required this.draftId,
    required this.targetId,
    required this.store,
    String? initialContent,
  }) : text = TextEditingController(text: initialContent) {
    text.addListener(_onChanged);
  }

  final String draftId;
  final String targetId;
  final DraftStore store;
  final TextEditingController text;

  Timer? _debounce;
  bool _disposed = false;

  void _onChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _save);
  }

  void _save() {
    if (_disposed) return;
    unawaited(store.save(draftId, targetId, text.text));
  }

  /// 立即落盘，绕过防抖（退后台时调用）。
  void flush() {
    _debounce?.cancel();
    if (_disposed) return;
    unawaited(store.save(draftId, targetId, text.text));
  }

  /// 提交 / 丢弃后删除草稿。
  Future<void> clear() => store.delete(draftId);

  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    text.removeListener(_onChanged);
    text.dispose();
  }
}

/// 多字段编辑草稿（详情页标题 / TL;DR / 正文），统一管理三个 [DraftController]。
class EditDraft {
  EditDraft({
    required this.baseId,
    required this.targetId,
    required this.store,
    required this.title,
    required this.tldr,
    required this.body,
  });

  final String baseId;
  final String targetId;
  final DraftStore store;
  final DraftController title;
  final DraftController tldr;
  final DraftController body;

  /// 用已落盘的草稿覆盖初始内容（优先草稿，无则保留初值）。
  Future<void> loadAll() async {
    final t = await store.load(title.draftId);
    if (t != null) title.text.text = t;
    final d = await store.load(tldr.draftId);
    if (d != null) tldr.text.text = d;
    final b = await store.load(body.draftId);
    if (b != null) body.text.text = b;
  }

  void flushAll() {
    title.flush();
    tldr.flush();
    body.flush();
  }

  Future<void> clearAll() async {
    await title.clear();
    await tldr.clear();
    await body.clear();
  }

  void dispose() {
    title.dispose();
    tldr.dispose();
    body.dispose();
  }
}
