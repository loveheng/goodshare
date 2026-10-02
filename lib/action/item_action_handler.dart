import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../ai/language_codes.dart';
import '../data/repository.dart';
import '../doc/rich_text.dart' show lostMediaUrls;
import '../models/item.dart';
import 'commands.dart';
import '../ai/video_clips.dart';
import 'machine_json_validator.dart';

/// UI / MCP / AI 管线共用的**唯一写入口**（Human-AI 对称架构的核心）。
///
/// 三条硬性质：
///
/// 1. **单一入参形态**：只接收 [ItemCommand]。UI 组装对象、MCP 反序列化 JSON、
///    AI 管线构造产出命令——核心逻辑不感知来源（无头化）。
/// 2. **防呆全下沉**：可见性、编辑锁、重分类白名单、machine_json Schema、
///    主体越权，全部在本类内部拦截。UI 把按钮置灰只是「快路径」而非安全边界
///    ——AI 是瞎子，看不到按钮灰没灰。
/// 3. **写后回状态**：每条命令都回 [CommandResult]，携带落库后的最新条目快照，
///    让大模型的短期记忆与数据库真实状态对齐。
///
/// 主体 × 命令 权限矩阵（越权在此拦截，绝不下放到传输层）：
///
/// | 命令 | ui | ai | pipeline |
/// |---|---|---|---|
/// | update / delete / reprocess / unlock_edit / collect / append_segment / restore / set_vault(on) | ✓ | ✓ | — |
/// | set_vault(off) 移出保险箱 | ✓ | ✗ 需生物识别 | — |
/// | delete_forever 彻底删除 | ✓ | ✗ 不可逆 | — |
/// | apply_ai_result 管线回写 | ✗ | ✗ | ✓ 独享重分类特权 |
///
/// 约束来源：编辑锁（设计 §4.9）、重分类白名单（F7 决策）、machine_json Schema（D4 决策）、
/// Vault 物理隔离（PRD §7 隐私硬约束）。
class ItemActionHandler {
  ItemActionHandler(
    this._repo, {
    this.mergeWindow = _defaultMergeWindow,
    this.onEnqueued,
  });

  final Repository _repo;

  /// 合并链追加窗口（设计 §4.9 / F6：同源连续收集在窗口内并链）。
  /// 单一事实源——`TextCollector` 的选链窗口直接取本值，避免两处窗口漂移。
  final Duration mergeWindow;

  /// 任务入队后回调（如触发 AI 队列立即处理）；UI 主动 reprocess 时用于绕过门控。
  final void Function()? onEnqueued;

  static const _defaultMergeWindow = Duration(minutes: 5);

  /// 执行单条命令——UI 与 AI 唯一的落库路径。
  ///
  /// [actor] 由传输层注入（不可由命令载荷伪造）；[vaultContext] 为 UI 保险箱页口径；
  /// [txn] 非空表示处于 [executeAll] 的批量事务中。
  Future<CommandResult> execute(
    ItemCommand cmd, {
    CommandActor actor = CommandActor.ui,
    bool vaultContext = false,
    Transaction? txn,
  }) {
    _gate(cmd, actor);
    final seeVault = _canSeeVault(actor, vaultContext);
    Future<CommandResult> dispatch() => _dispatch(cmd, actor, seeVault, txn);
    // 写路径串行化：把「读 → 校验 → 写」压成 FIFO，消除并发交错导致的
    // 基于过期快照校验 + 后写覆盖先写（TOCTOU）。已在批量事务中时由 executeAll 统一持锁。
    return txn == null ? _repo.synchronized(dispatch) : dispatch();
  }

  Future<CommandResult> _dispatch(
    ItemCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) =>
      switch (cmd) {
        final UpdateItemCommand c => _update(c, actor, seeVault, txn),
      final DeleteItemCommand c => _delete(c, seeVault, txn),
      final SetVaultCommand c => _setVault(c, actor, seeVault, txn),
      final ReclassifyCommand c => _reclassify(c, actor, seeVault, txn),
      final ReprocessCommand c => _reprocess(c, seeVault, txn),
      final TranscribeCommand c => _transcribe(c, seeVault, txn),
      final SummarizeCommand c => _summarize(c, seeVault, txn),
      final ExtractTagsCommand c => _extractTags(c, seeVault, txn),
      final OcrCommand c => _ocr(c, seeVault, txn),
      final ClassifyCommand c => _classify(c, seeVault, txn),
      final ScanBarcodeCommand c => _scanBarcode(c, seeVault, txn),
      final AnalyzeTextCommand c => _analyzeText(c, seeVault, txn),
      final ClipCommand c => _clip(c, seeVault, txn),
      final ClipProcessCommand c => _clipProcess(c, seeVault, txn),
      final TranslateCommand c => _translate(c, seeVault, txn),
      final UnlockEditCommand c => _unlockEdit(c, seeVault, txn),
      final RestoreCommand c => _restore(c, seeVault, txn),
      final DeleteForeverCommand c => _deleteForever(c, txn),
      final CollectCommand c => _collect(c, txn),
      final AppendSegmentCommand c => _append(c, seeVault, txn),
        final ApplyAiResultCommand c => _applyAiResult(c, actor, seeVault, txn),
        final CreateWorkspaceCommand c => _createWorkspace(c),
        final RenameWorkspaceCommand c => _renameWorkspace(c),
        final DeleteWorkspaceCommand c => _deleteWorkspace(c),
        final AddToWorkspaceCommand c => _addToWorkspace(c, seeVault, txn),
        final RemoveFromWorkspaceCommand c => _removeFromWorkspace(c),
        final MigrateAttachCommand c => _migrateAttach(c, txn),
      };

  /// 原子批量执行：一条命令失败则整批回滚，杜绝「字改了但标签没打上」的脏数据。
  ///
  /// 服务于两种复合场景：AI 在一个 JSON 里同时发「解锁 + 改字 + 打标签」；
  /// UI 复杂表单一次提交多字段改动。两者走同一个接口，语义完全一致。
  Future<List<CommandResult>> executeAll(
    List<ItemCommand> cmds, {
    CommandActor actor = CommandActor.ui,
    bool vaultContext = false,
  }) async {
    if (cmds.isEmpty) {
      throw ActionException('批量命令为空', code: ActionErrorCode.invalidRequest);
    }
    if (cmds.length == 1) {
      return [await execute(cmds.single, actor: actor, vaultContext: vaultContext)];
    }
    // 附件删除是文件系统副作用，不随事务回滚——禁止混入批量事务
    for (final c in cmds) {
      if (c is DeleteForeverCommand) {
        throw ActionException(
          '批量事务不支持 delete_forever（附件删除不可回滚）',
          code: ActionErrorCode.invalidRequest,
          hint: '彻底删除请单独执行',
        );
      }
    }
    // 事务 + 串行锁双重保障：事务保证原子性，锁保证不与其它客户端的写交错
    return _repo.synchronized(
      () => _repo.transaction((txn) async {
        final results = <CommandResult>[];
        for (final c in cmds) {
          results.add(await execute(c, actor: actor, vaultContext: vaultContext, txn: txn));
        }
        return results;
      }),
    );
  }

  // ---- 各命令实现（校验即在此，UI/AI 都绕不过） ----

  Future<CommandResult> _update(
    UpdateItemCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.editLocked) {
      throw ActionException(
        '合并条目已锁定，请先「解除编辑」',
        code: ActionErrorCode.editLocked,
        hint: '先执行 unlock_edit(id=${cmd.id}) 再重试 update',
      );
    }
    final values = <String, Object?>{};
    if (cmd.title != null) values['human_title'] = cmd.title;
    if (cmd.tldr != null) values['human_tldr'] = cmd.tldr;
    if (cmd.tags != null) values['tags'] = jsonEncode(cmd.tags);
    if (cmd.humanMd != null) values['human_md'] = cmd.humanMd;
    if (cmd.inspirationMd != null) values['inspiration_md'] = cmd.inspirationMd;
    if (cmd.machineJson != null) {
      final err = validateMachineJson(cmd.machineJson);
      if (err != null) throw ActionException(err, code: ActionErrorCode.schemaInvalid);
      values['machine_json'] = cmd.machineJson;
    }
    if (cmd.itemType != null && cmd.itemType != item.itemType) {
      final err = _reclassifyError(item, cmd.itemType!, privilege: actor == CommandActor.pipeline);
      if (err != null) {
        throw ActionException(
          err,
          code: ActionErrorCode.reclassifyDenied,
          hint: '人工/AI 客户端仅允许 image→document（发票 / 文档截图），且须 source_type=image',
        );
      }
      values['item_type'] = cmd.itemType;
    }
    if (values.isEmpty) throw ActionException('没有可更新的字段', code: ActionErrorCode.invalidRequest);
    await _write('update', cmd.id, values, expectedVersion: cmd.expectedVersion, txn: txn);
    return _result('update', cmd.id, seeVault: seeVault, txn: txn, note: '已更新');
  }

  Future<CommandResult> _delete(DeleteItemCommand cmd, bool seeVault, Transaction? txn) async {
    await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (!await _repo.softDelete(cmd.id, expectedVersion: cmd.expectedVersion, txn: txn)) {
      throw _conflict('delete');
    }
    return _result('delete', cmd.id, seeVault: seeVault, txn: txn, note: '已删除（30 天内可恢复）');
  }

  Future<CommandResult> _setVault(
    SetVaultCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    // 防呆下沉：此规则原写在 MCP 层，AI 换个入口即可绕过——现收口到动作层
    if (!cmd.on && actor != CommandActor.ui) {
      throw ActionException(
        '移出保险箱须用户在手机上操作',
        code: ActionErrorCode.forbidden,
        hint: 'AI 只能移入（set_vault on=true）；移出需用户在手机端生物识别',
      );
    }
    if (!cmd.on && !item.isVault) {
      throw ActionException('条目不在保险箱中，无需移出', code: ActionErrorCode.invalidRequest);
    }
    await _write(
      'set_vault',
      cmd.id,
      {'is_vault': cmd.on ? 1 : 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    return _result(
      'set_vault',
      cmd.id,
      seeVault: seeVault,
      txn: txn,
      note: cmd.on ? '已移入保险箱' : '已移出保险箱',
    );
  }

  Future<CommandResult> _reclassify(
    ReclassifyCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final err = _reclassifyError(item, cmd.to, privilege: actor == CommandActor.pipeline);
    if (err != null) {
      throw ActionException(
        err,
        code: ActionErrorCode.reclassifyDenied,
        hint: '可选目标：${InboxItem.typeDocument}（发票 / 文档截图）',
      );
    }
    await _write(
      'reclassify',
      cmd.id,
      {'item_type': cmd.to},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    return _result('reclassify', cmd.id, seeVault: seeVault, txn: txn, note: '已重分类');
  }

  Future<CommandResult> _reprocess(ReprocessCommand cmd, bool seeVault, Transaction? txn) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    await _write(
      'reprocess',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    // 图片「重新处理」= 重新 OCR（2026-09-28 用户口径：摄入不自动 OCR，但点重新处理
    // 就要出文字）；音频仍只认手动「转写」入口，其 reprocess 仅占位、不跑模型。
    final action = item.itemType == InboxItem.typeImage
        ? Repository.taskOcrAndExtract
        : Repository.taskActionFor(item.itemType);
    final jobId = await _repo.enqueueTask(cmd.id, action, txn: txn);
    onEnqueued?.call();
    return _result('reprocess', cmd.id, seeVault: seeVault, txn: txn, note: '已重新入队', jobId: jobId);
  }

  /// 手动转写音频 / 视频：显式入队 transcribe_audio（2026-09-28 用户拍板——
  /// 音频不做实时转写、摄入也不自动转写，只存文件；转写必须用户手动触发）。
  ///
  /// 「仅音频 / 视频可转写」的校验下沉在动作层：AI / MCP 换个入口也绕不过。
  Future<CommandResult> _transcribe(
    TranscribeCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.itemType != InboxItem.typeAudio && item.itemType != InboxItem.typeVideo) {
      throw ActionException(
        '只有音频 / 视频能转写（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
        hint: '图片请点「重新处理」走 OCR',
      );
    }
    // 字幕模式 / 目标语言的任务级覆盖：合法性在此下沉（AI 换入口也绕不过），
    // 编码进动作串由 AsrReconstructor 解析（translate:<lang> 同口径）。
    final mode = cmd.subtitleMode?.trim();
    if (mode != null && mode.isNotEmpty && !Repository.transcribeSubtitleModes.contains(mode)) {
      throw ActionException(
        '不支持的字幕译文模式：$mode',
        code: ActionErrorCode.invalidRequest,
        hint: '可选：${Repository.transcribeSubtitleModes.join(', ')}',
      );
    }
    final lang = cmd.targetLang?.trim();
    if (lang != null && lang.isNotEmpty && !isSupportedTarget(lang)) {
      throw ActionException(
        '不支持的目标语言：$lang',
        code: ActionErrorCode.invalidRequest,
        hint: '可选：${kTargetLanguages.join(', ')}',
      );
    }
    await _write(
      'transcribe',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(
      cmd.id,
      Repository.transcribeTaskAction(subtitleMode: mode, targetLang: lang),
      txn: txn,
    );
    onEnqueued?.call();
    return _result('transcribe', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始转写'));
  }

  /// 手动 OCR 图片：显式入队 ocr_and_extract（2026-09-28 用户拍板——分享摄入不默认
  /// OCR，只存文件；识别文字必须用户手动触发，与音频转写对称）。
  ///
  /// 「仅图片可 OCR」的校验下沉在动作层：AI / MCP 换个入口也绕不过。
  Future<CommandResult> _ocr(
    OcrCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.itemType != InboxItem.typeImage) {
      throw ActionException(
        '只有图片能识别文字（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
        hint: '音频 / 视频请点「转写」',
      );
    }
    await _write(
      'ocr',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.taskOcrAndExtract, txn: txn);
    onEnqueued?.call();
    return _result('ocr', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始识别文字'));
  }

  /// 手动图片分类：显式入队 classify_image（2026-09-29，与 OCR / 转写对称——
  /// 端侧重资源动作一律手动 / 显式触发，摄入不自动跑模型）。
  ///
  /// 「仅图片可分类」的校验下沉在动作层：AI / MCP 换个入口也绕不过。
  Future<CommandResult> _classify(
    ClassifyCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.itemType != InboxItem.typeImage) {
      throw ActionException(
        '只有图片能分类（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    await _write(
      'classify',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.taskClassifyImage, txn: txn);
    onEnqueued?.call();
    return _result('classify', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始识别分类'));
  }

  /// 手动扫描条码：显式入队 scan_barcode（2026-09-29，与 OCR / 分类对称——
  /// 端侧重资源动作一律手动 / 显式触发，摄入不自动跑模型）。
  /// 「仅图片可扫描」的校验下沉在动作层：AI / MCP 换个入口也绕不过。
  Future<CommandResult> _scanBarcode(
    ScanBarcodeCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.itemType != InboxItem.typeImage) {
      throw ActionException(
        '只有图片能扫描条码（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    await _write(
      'scan_barcode',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.taskScanBarcode, txn: txn);
    onEnqueued?.call();
    return _result('scan_barcode', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始识别条码'));
  }

  /// 手动文本分析：显式入队 analyze_text（2026-09-29，与 OCR / 分类 / 条码对称——
  /// 端侧重资源动作一律手动 / 显式触发，摄入不自动跑模型）。
  /// 「仅笔记可分析」的校验下沉在动作层：AI / MCP 换个入口也绕不过。
  Future<CommandResult> _analyzeText(
    AnalyzeTextCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.itemType != InboxItem.typeNote) {
      throw ActionException(
        '只有笔记能分析文本（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    await _write(
      'analyze_text',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.taskAnalyzeText, txn: txn);
    onEnqueued?.call();
    return _result('analyze_text', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始分析文本'));
  }

  /// 视频切片：登记关键区间并入队转写+摘要任务（2026-09-29，设计 docs/design/video-clips.md）。
  ///
  /// 校验下沉在动作层：仅视频条目、区间时长合法、不与既有区间重复——
  /// AI / MCP 换个入口也绕不过。登记即入队：区间先以空产出落 clips_json，
  /// 队列完成后按区间回填（用户可见「待处理 → 有文本 → 有摘要」全过程）。
  Future<CommandResult> _clip(
    ClipCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.itemType != InboxItem.typeVideo) {
      throw ActionException(
        '只有视频能切片（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    if (!isValidClipInterval(cmd.startMs, cmd.endMs)) {
      throw ActionException(
        '切片区间非法（需 1 秒 ~ 30 分钟，且起点小于终点）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    final clips = parseClipsJson(item.clipsJson);
    if (clips.any((c) => c.startMs == cmd.startMs && c.endMs == cmd.endMs)) {
      throw ActionException(
        '该区间已存在',
        code: ActionErrorCode.invalidRequest,
        hint: '可在切片列表里查看已有区间',
      );
    }
    final updated = [
      ...clips,
      ClipSegment(startMs: cmd.startMs, endMs: cmd.endMs, createdAt: DateTime.now().millisecondsSinceEpoch),
    ];
    await _write(
      'clip',
      cmd.id,
      {'clips_json': encodeClipsJson(updated)},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    // 标记 ≠ 处理（2026-09-29 改版拍板）：标记只记时间点供快速跳转，
    // 处理由 ClipProcessCommand 显式触发——端侧重资源动作一律手动。
    return _result('clip', cmd.id, seeVault: seeVault, txn: txn,
        note: '已标记（处理后才算收藏完成）');
  }

  /// 翻译条目正文：显式入队 translate（与 OCR / 转写同构——端侧重资源动作
  /// 一律手动 / 显式触发，摄入不自动跑）。
  ///
  /// 校验下沉在动作层：正文非空 + 目标语言合法，AI / MCP 换个入口也绕不过。
  Future<CommandResult> _translate(
    TranslateCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.bodyText.trim().isEmpty) {
      throw ActionException(
        '该条目没有可翻译的正文',
        code: ActionErrorCode.invalidRequest,
        hint: '图片 / 音视频请先「识别文字」或「转写」出文本，再翻译',
      );
    }
    final lang = cmd.targetLang;
    if (lang != null && !isSupportedTarget(lang)) {
      throw ActionException(
        '不支持的目标语言：$lang',
        code: ActionErrorCode.invalidRequest,
        hint: '可选：${kTargetLanguages.join(', ')}',
      );
    }
    await _write(
      'translate',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.translateTaskAction(lang), txn: txn);
    onEnqueued?.call();
    return _result('translate', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始翻译'));
  }

  /// 端侧 LLM 摘要：显式入队 llm_summarize（2026-09-28，设计见 docs/design/on-device-llm.md）。
  ///
  /// 与 OCR / 转写 / 翻译同构——端侧重资源动作一律手动 / 显式触发。
  /// 「文本类条目且正文非空」校验下沉在动作层：AI / MCP 换个入口也绕不过。
  Future<CommandResult> _summarize(
    SummarizeCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.bodyText.trim().isEmpty) {
      throw ActionException(
        '该条目没有可摘要的正文',
        code: ActionErrorCode.invalidRequest,
        hint: '图片 / 音视频请先「识别文字」或「转写」出文本，再摘要',
      );
    }
    await _write(
      'summarize',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.taskLlmSummarize, txn: txn);
    onEnqueued?.call();
    return _result('summarize', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始生成摘要'));
  }

  /// 端侧 LLM 关键词提取：显式入队 llm_tags，产出并入既有标签体系。
  Future<CommandResult> _extractTags(
    ExtractTagsCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.bodyText.trim().isEmpty) {
      throw ActionException(
        '该条目没有可提取关键词的正文',
        code: ActionErrorCode.invalidRequest,
        hint: '图片 / 音视频请先「识别文字」或「转写」出文本，再提取关键词',
      );
    }
    await _write(
      'extract_tags',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.taskLlmTags, txn: txn);
    onEnqueued?.call();
    return _result('extract_tags', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始提取关键词'));
  }

  /// 入队后的提示文案：本任务之前仍有排队任务时，明确告知「已放入任务列表」及条数，
  /// 避免用户以为点击没生效（前面排队时需要等待）。[immediate] 为无需排队时的文案。
  Future<String> _queuedNote(String immediate) async {
    final total = await _repo.pendingCount(); // 含刚入队的本条
    final ahead = total - 1;
    return ahead > 0 ? '已放入任务列表，前面还有 $ahead 条待处理' : immediate;
  }

  Future<CommandResult> _unlockEdit(UnlockEditCommand cmd, bool seeVault, Transaction? txn) async {
    await _require(cmd.id, seeVault: seeVault, txn: txn);
    await _write(
      'unlock_edit',
      cmd.id,
      {'edit_locked': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    return _result('unlock_edit', cmd.id, seeVault: seeVault, txn: txn, note: '已解除编辑锁定');
  }

  Future<CommandResult> _restore(RestoreCommand cmd, bool seeVault, Transaction? txn) async {
    final item = await _repo.byId(cmd.id, includeDeleted: true, includeVault: true, txn: txn);
    if (item == null) {
      throw ActionException('条目不存在：id=${cmd.id}', code: ActionErrorCode.notFound);
    }
    if (!item.isDeleted) {
      throw ActionException('条目未处于删除状态，无需恢复', code: ActionErrorCode.invalidRequest);
    }
    if (!await _repo.restore(cmd.id, txn: txn)) throw _conflict('restore');
    return _result('restore', cmd.id, seeVault: seeVault, txn: txn, note: '已恢复');
  }

  /// 彻底删除（含附件，不可恢复）。Actor 已门控为 [CommandActor.ui]。
  Future<CommandResult> _deleteForever(DeleteForeverCommand cmd, Transaction? txn) async {
    final item = await _repo.byId(cmd.id, includeDeleted: true, includeVault: true, txn: txn);
    if (item == null) {
      throw ActionException('条目不存在：id=${cmd.id}', code: ActionErrorCode.notFound);
    }
    await _repo.deleteForever(cmd.id, txn: txn);
    return CommandResult(op: 'delete_forever', targetId: cmd.id, note: '已彻底删除（不可恢复）');
  }

  Future<CommandResult> _collect(CollectCommand cmd, Transaction? txn) async {
    final hasContent = (cmd.rawContent != null && cmd.rawContent!.trim().isNotEmpty) ||
        (cmd.rawFilePath != null && cmd.rawFilePath!.isNotEmpty);
    if (!hasContent) {
      throw ActionException(
        'collect 必须有正文或附件',
        code: ActionErrorCode.invalidRequest,
        hint: '文本/链接传 content；媒体附件传 file（须为 app 私有目录路径）',
      );
    }
    if (!InboxItem.allTypes.contains(cmd.itemType)) {
      throw ActionException(
        '未知条目类型：${cmd.itemType}',
        code: ActionErrorCode.invalidRequest,
        hint: '可选：${InboxItem.allTypes.join(', ')}',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final merge = cmd.isMerge;
    final item = await _repo.add(
      InboxItem(
        itemType: cmd.itemType,
        sourceType: cmd.itemType,
        sourceApp: cmd.sourceApp,
        rawContent: cmd.rawContent,
        rawFilePath: cmd.rawFilePath,
        humanTitle: cmd.humanTitle,
        tags: cmd.tags ?? const [],
        collectMode: cmd.collectMode,
        attachState: cmd.attachState,
        aspectRatio: cmd.aspectRatio,
        mediaDurationMs: cmd.mediaDurationMs,
        // 合并链：新链即锁定（须先「解除编辑」），首段同样记入 appendix（设计 §4.9）
        editLocked: merge,
        appendix: merge && cmd.rawContent != null
            ? [AppendixEntry(ts: now, text: cmd.rawContent!, source: cmd.sourceApp)]
            : const [],
        createdAt: now,
      ),
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(item.id!, Repository.taskActionFor(item.itemType), txn: txn);
    return CommandResult(op: 'collect', targetId: item.id, item: item, note: '已收集', jobId: jobId);
  }

  /// 往合并链追加一段。**合并条目 `edit_locked=1` 仍允许追加**——追加是链的持续生长，
  /// 不等同于改写已有内容，该豁免是显式领域语义（不是绕过校验）。
  ///
  /// 模式与窗口约束全部在此判定（防呆下沉）：AI 经 `append_segment` 与手机连续速记
  /// 受**同一套**约束，客户端策略只负责"选哪条链"。
  Future<CommandResult> _append(AppendSegmentCommand cmd, bool seeVault, Transaction? txn) async {
    final text = cmd.text.trim();
    if (text.isEmpty) {
      throw ActionException('追加文本不能为空', code: ActionErrorCode.invalidRequest);
    }
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.collectMode != InboxItem.modeMerge) {
      throw ActionException(
        '仅合并模式条目可追加段',
        code: ActionErrorCode.invalidRequest,
        hint: '散列条目请改用 update 改写内容，或 collect 新建一条',
      );
    }
    final lastTs = [
      item.createdAt,
      if (item.appendix.isNotEmpty) item.appendix.last.ts,
    ].reduce((a, b) => a > b ? a : b);
    if (lastTs < DateTime.now().subtract(mergeWindow).millisecondsSinceEpoch) {
      throw ActionException(
        '超出合并窗口（${mergeWindow.inMinutes} 分钟），不得追加',
        code: ActionErrorCode.invalidRequest,
        hint: '改用 collect 新建一条',
      );
    }
    final appendix = [
      ...item.appendix,
      AppendixEntry(ts: DateTime.now().millisecondsSinceEpoch, text: text, source: cmd.sourceApp),
    ];
    await _write(
      'append_segment',
      cmd.id,
      {
        'raw_content': '${item.rawContent ?? ''}\n$text',
        'appendix_json': jsonEncode([for (final a in appendix) a.toJson()]),
      },
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.taskActionFor(item.itemType), txn: txn);
    return _result('append_segment', cmd.id, seeVault: seeVault, txn: txn, note: '已追加到合并链', jobId: jobId);
  }

  /// 视频切片处理：对已标记区间执行用户勾选的链路子集（提取/转写/摘要）。
  /// 步骤规整（E2 摘要带动转写）与区间存在性校验下沉在动作层；登记 processing
  /// 状态后入队 `clip:<s>-<e>:<steps>` 任务，完成/失败由管线回写。
  Future<CommandResult> _clipProcess(
    ClipProcessCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (item.itemType != InboxItem.typeVideo) {
      throw ActionException(
        '只有视频能切片处理（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    if (!isValidClipInterval(cmd.startMs, cmd.endMs)) {
      throw ActionException(
        '切片区间非法（需 1 秒 ~ 30 分钟，且起点小于终点）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    final steps = normalizeClipSteps(cmd.steps);
    if (steps.isEmpty) {
      throw ActionException(
        '请至少勾选一个处理步骤（提取片段 / 转写 / 摘要）',
        code: ActionErrorCode.invalidRequest,
      );
    }
    final clips = parseClipsJson(item.clipsJson);
    final idx = clips.indexWhere((c) => c.startMs == cmd.startMs && c.endMs == cmd.endMs);
    if (idx == -1) {
      throw ActionException(
        '该区间尚未标记',
        code: ActionErrorCode.invalidRequest,
        hint: '先在切片编辑里标记区间，再触发处理',
      );
    }
    final updated = [...clips]..[idx] = clips[idx].copyWith(
        steps: steps,
        status: kClipStatusProcessing,
        note: null,
      );
    await _write(
      'clip_process',
      cmd.id,
      {'clips_json': encodeClipsJson(updated)},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    final jobId = await _repo.enqueueTask(cmd.id, Repository.clipTaskAction(cmd.startMs, cmd.endMs, steps), txn: txn);
    onEnqueued?.call();
    return _result('clip_process', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始处理切片'));
  }

  /// AI 管线回写产出。Actor 已门控为 [CommandActor.pipeline]——
  /// 若对 MCP 开放，大模型即可绕过 edit_locked 直接改写条目。
  Future<CommandResult> _applyAiResult(
    ApplyAiResultCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final r = cmd.result;
    // 视频切片产出走独立通道：只合并进 clips_json（派生附属记录），**不触碰**
    // human_md / summary_md 等条目级字段——区间结果不得覆盖整片产物。
    if (r.clip != null) {
      final merged = mergeClipResult(parseClipsJson(item.clipsJson), r.clip!);
      await _write('apply_ai_result', cmd.id, {'clips_json': encodeClipsJson(merged)},
          expectedVersion: cmd.expectedVersion, txn: txn);
      return _result('apply_ai_result', cmd.id, seeVault: seeVault, txn: txn,
          note: '已回写切片产出（${r.clip!.status == kClipStatusDone ? '完成' : r.clip!.status}）');
    }
    // 防冲刷护城河（2026-09-30 拍板叮嘱②）：AI 产出的 human_md 若丢失原文的
    // 行内媒体块，说明模型删了用户资产——human_md 保留原文（其余字段照常应用），
    // 原因进 result.note 可感知（R1）。只拦管线回写；UI/MCP update 走块编辑器，
    // 用户手动删媒体是合法操作。
    final lostMedia = lostMediaUrls(item.humanMd ?? '', r.humanMd);
    final guarded = lostMedia.isNotEmpty;
    final values = <String, Object?>{
      'human_md': guarded ? (item.humanMd ?? '') : r.humanMd,
      'is_processed': 1,
    };
    if (r.machineJson != null) {
      final raw = jsonEncode(r.machineJson);
      final err = validateMachineJson(raw);
      if (err != null) {
        throw ActionException('AI 产出 machine_json 校验不过：$err', code: ActionErrorCode.schemaInvalid);
      }
      values['machine_json'] = raw;
    }
    if (r.tags.isNotEmpty) {
      // 并集合并（2026-10-01 拍板）：AI 重新提取只增不删——标签的用户权威
      // 在人（手动增删走 update 命令整表替换），AI 提取只是代劳不全量覆写。
      final merged = <String>[...item.tags];
      for (final t in r.tags) {
        if (!merged.contains(t)) merged.add(t);
      }
      values['tags'] = jsonEncode(merged);
    }
    if (r.itemType != null && r.itemType != item.itemType) {
      if (actor != CommandActor.pipeline) {
        final err = _reclassifyError(item, r.itemType!, privilege: false);
        if (err != null) throw ActionException(err, code: ActionErrorCode.reclassifyDenied);
      }
      values['item_type'] = r.itemType;
    }
    if (r.facets != null) values['facets_json'] = jsonEncode(r.facets);
    // 译文与原文并列存储：翻译层只追加译文，绝不覆盖 human_md
    if (r.translatedMd != null) {
      values['translated_md'] = r.translatedMd;
      values['translate_lang'] = r.translateLang ?? '';
    }
    // 端侧 LLM 摘要与原文并列存储（2026-09-28 v8）：只追加，不覆盖 human_md
    if (r.summaryMd != null) {
      values['summary_md'] = r.summaryMd;
    }
    // 文档归一化元信息（2026-09-30）：覆盖率 / 降级 / 确认状态，供 UI 明示
    // 「提取了多少、哪些降级了」——降级不允许静默成功（content-pipeline §7）。
    if (r.docMetaJson != null) {
      values['doc_meta_json'] = r.docMetaJson;
    }
    await _write('apply_ai_result', cmd.id, values, expectedVersion: cmd.expectedVersion, txn: txn);
    return _result('apply_ai_result', cmd.id, seeVault: seeVault, txn: txn,
        note: guarded
            ? 'AI 产出丢失行内媒体块（${lostMedia.length} 个），已保留原文；其余字段照常回写'
            : '已回写 AI 产出');
  }

  // ---- 工作区（2026-09-30：条目集合容器，多对多，见 ui-spec §4.11） ----
  //
  // 工作区操作对象不是条目，无乐观锁语义（工作区无并发编辑冲突面）；
  // add/remove 对条目走 _require 可见性校验——Vault 条目对 AI 不可见，
  // 工作区不得成为隐私隔离的后门。

  Future<CommandResult> _createWorkspace(CreateWorkspaceCommand cmd) async {
    final name = cmd.name.trim();
    if (name.isEmpty) {
      throw ActionException('工作区名称不能为空', code: ActionErrorCode.invalidRequest);
    }
    final ws = await _repo.createWorkspace(name);
    return CommandResult(
      op: 'create_workspace',
      targetId: ws.id,
      note: '已创建工作区「${ws.name}」',
    );
  }

  Future<CommandResult> _renameWorkspace(RenameWorkspaceCommand cmd) async {
    final name = cmd.name.trim();
    if (name.isEmpty) {
      throw ActionException('工作区名称不能为空', code: ActionErrorCode.invalidRequest);
    }
    final existing = await _repo.byIdWorkspace(cmd.workspaceId);
    if (existing == null) {
      throw ActionException(
        '工作区不存在：id=${cmd.workspaceId}',
        code: ActionErrorCode.notFound,
        hint: '先执行 list_workspaces 确认 id',
      );
    }
    await _repo.renameWorkspace(cmd.workspaceId, name);
    return CommandResult(
      op: 'rename_workspace',
      targetId: cmd.workspaceId,
      note: '已重命名为「$name」',
    );
  }

  Future<CommandResult> _deleteWorkspace(DeleteWorkspaceCommand cmd) async {
    final existing = await _repo.byIdWorkspace(cmd.workspaceId);
    if (existing == null) {
      throw ActionException(
        '工作区不存在：id=${cmd.workspaceId}',
        code: ActionErrorCode.notFound,
        hint: '先执行 list_workspaces 确认 id',
      );
    }
    await _repo.deleteWorkspace(cmd.workspaceId);
    return CommandResult(
      op: 'delete_workspace',
      targetId: cmd.workspaceId,
      note: '已删除工作区「${existing.name}」（条目本身不受影响）',
    );
  }

  Future<CommandResult> _addToWorkspace(
    AddToWorkspaceCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final ws = await _repo.byIdWorkspace(cmd.workspaceId, txn: txn);
    if (ws == null) {
      throw ActionException(
        '工作区不存在：id=${cmd.workspaceId}',
        code: ActionErrorCode.notFound,
        hint: '先执行 list_workspaces 确认 id',
      );
    }
    await _require(cmd.itemId, seeVault: seeVault, txn: txn);
    await _repo.addToWorkspace(cmd.workspaceId, cmd.itemId, txn: txn);
    return _result('add_to_workspace', cmd.itemId, seeVault: seeVault, txn: txn,
        note: '已加入工作区「${ws.name}」');
  }

  Future<CommandResult> _removeFromWorkspace(RemoveFromWorkspaceCommand cmd) async {
    final ws = await _repo.byIdWorkspace(cmd.workspaceId);
    if (ws == null) {
      throw ActionException(
        '工作区不存在：id=${cmd.workspaceId}',
        code: ActionErrorCode.notFound,
        hint: '先执行 list_workspaces 确认 id',
      );
    }
    await _repo.removeFromWorkspace(cmd.workspaceId, cmd.itemId);
    return _result('remove_from_workspace', cmd.itemId,
        seeVault: false, note: '已移出工作区「${ws.name}」');
  }

  // ---- 只读 / 批量维护（非命令：查询与例行清理，无脏数据风险） ----

  /// 列出已软删除且在保留期内的条目（最近删除页读取）。
  Future<List<InboxItem>> listDeleted() => _repo.listDeleted();

  /// 合并模式的追加候选（供 `TextCollector` 选链）。
  /// 注意：这里只做查询过滤，**窗口与模式校验仍在 `execute` 内**再拦一次。
  Future<List<InboxItem>> recentMergeItems({String? sourceApp, int limit = 5}) =>
      _repo.recentMergeItems(sourceApp: sourceApp, limit: limit);

  /// 清空所有已删除条目（最近删除页，UI 二次确认后调用）。
  Future<void> purgeAllDeleted() => _repo.purgeAllDeleted();

  /// 把尚未产出人类态的音频条目重新入队（幂等：已转写的不再处理）。
  /// 用于 ASR 能力/模型就绪后，补跑存量未转写音频。
  Future<void> requeueUnprocessedAudio() async {
    final items = await _repo.list(type: InboxItem.typeAudio, limit: 200);
    for (final it in items) {
      if (it.humanMd == null || it.humanMd!.isEmpty) {
        await _repo.enqueueTask(it.id!, Repository.taskTranscribeAudio);
      }
    }
  }

  // ---- 领域规则 ----

  /// 写路径统一出口（乐观锁 CAS）：所有 `_repo.update` 必须经此，
  /// 漏掉即意味着该命令可以被静默覆盖。返回 false（版本不符）时抛冲突异常。
  Future<void> _write(
    String op,
    String id,
    Map<String, Object?> values, {
    int? expectedVersion,
    Transaction? txn,
  }) async {
    final ok = await _repo.update(id, values, expectedVersion: expectedVersion, txn: txn);
    if (!ok) throw _conflict(op);
  }

  /// 版本冲突异常：人类与 AI 谁后提交谁撞上，责任边界清晰。
  /// UI 提示「数据已刷新」；AI 收到后重新读取最新 version 再决策。
  ActionException _conflict(String op) => ActionException(
        '版本冲突：条目已被其他人或 AI 修改（op=$op），请刷新后重试',
        code: ActionErrorCode.versionConflict,
        hint: '重新读取条目取最新 version，再带 expected_version 重试',
      );

  /// 引用附件迁移（ref → owned）：大文件复制已由调用方在锁外完成，
  /// 此处只做持有态交换的防呆与 DB 写——校验 ref 态、副本文件存在、
  /// 乐观锁 CAS，三道防线全在动作层（UI/MCP 同源）。
  Future<CommandResult> _migrateAttach(MigrateAttachCommand cmd, Transaction? txn) async {
    final item = await _require(cmd.id, seeVault: true, txn: txn);
    if (!item.isRef) {
      throw ActionException(
        '条目不是引用态，无需迁移：attach_state=${item.attachState}',
        code: ActionErrorCode.invalidRequest,
        hint: '仅 attach_state=ref（引用原件）的条目可迁移',
      );
    }
    if (cmd.ownedPath.isEmpty || !File(cmd.ownedPath).existsSync()) {
      throw ActionException(
        '迁移副本不存在：${cmd.ownedPath}',
        code: ActionErrorCode.invalidRequest,
        hint: '先把原件复制进私有目录，再发本命令',
      );
    }
    final ok = await _repo.update(
      cmd.id,
      {'raw_file_path': cmd.ownedPath, 'attach_state': InboxItem.attachOwned},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    if (!ok) throw _conflict('migrate_attach');
    return _result('migrate_attach', cmd.id, seeVault: true, txn: txn, note: '已迁移为本地持有');
  }

  /// 主体门控：越权在此拦截，不由传输层判断。
  void _gate(ItemCommand cmd, CommandActor actor) {
    final allowed = switch (cmd) {
      ApplyAiResultCommand() => actor == CommandActor.pipeline,
      DeleteForeverCommand() => actor == CommandActor.ui,
      _ => true,
    };
    if (!allowed) {
      throw ActionException(
        '主体 ${actor.name} 无权执行 ${cmd.op}',
        code: ActionErrorCode.forbidden,
        hint: '该命令仅内部管线/手机端可用，AI 客户端请改用受约束的公开命令',
      );
    }
  }

  /// Vault 可见性：AI（MCP）永不可见；UI 需 vaultContext（保险箱页口径）；
  /// 端侧管线本机运行、不属于对外暴露面，可见（否则 Vault 条目入队后必然死信）。
  static bool _canSeeVault(CommandActor actor, bool vaultContext) =>
      actor == CommandActor.pipeline || (actor == CommandActor.ui && vaultContext);

  /// 重分类白名单校验。返回 null 表示允许，否则为拒绝原因。
  /// [privilege] 为 AI 管线特权（V2 §3.8）：为 true 时不受人工白名单约束。
  String? _reclassifyError(InboxItem item, String to, {required bool privilege}) {
    if (!InboxItem.allTypes.contains(to)) return '未知类型：$to';
    if (privilege) return null;
    if (item.sourceType != InboxItem.typeImage || item.itemType != InboxItem.typeImage) {
      return '仅图片入库（source_type=image）的条目可重分类';
    }
    // 目标只剩 document（2026-10-02 拍板：**聊天场景取消**——chatlog 是早期
    // 没想清楚的设计，不再作为可改判目标；旧 chatlog 数据仍照常渲染）。
    if (to != InboxItem.typeDocument) {
      return '仅允许 image→document（发票 / 文档截图）';
    }
    return null;
  }

  Future<InboxItem> _require(String id, {required bool seeVault, Transaction? txn}) async {
    final item = await _repo.byId(id, includeDeleted: false, includeVault: seeVault, txn: txn);
    if (item == null) {
      throw ActionException(
        '条目不存在或不可见：id=$id',
        code: ActionErrorCode.notFound,
        hint: '先用 list_items 确认条目 id；Vault 与已删条目对 MCP 不可见',
      );
    }
    return item;
  }

  /// 统一回传落库后的最新快照。**条目移出可见域后不再回传内容**（隐私硬约束）。
  Future<CommandResult> _result(
    String op,
    String id, {
    required bool seeVault,
    Transaction? txn,
    String? note,
    String? jobId,
  }) async {
    final fresh = await _repo.byId(id, includeDeleted: true, includeVault: true, txn: txn);
    if (fresh == null) return CommandResult(op: op, targetId: id, note: note, jobId: jobId);
    final visible = seeVault || !fresh.isVault;
    return CommandResult(op: op, targetId: id, item: visible ? fresh : null, note: note, jobId: jobId);
  }
}
