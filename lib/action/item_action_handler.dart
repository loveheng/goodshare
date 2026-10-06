import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../ai/language_codes.dart';
import '../data/block_artifacts.dart' show BlockArtifactKind;
import '../data/repository.dart';
import '../doc/rich_text.dart'
    show
        AudioBlock,
        ImageBlock,
        MarkdownSubsetParser,
        MediaSuffix,
        QuoteBlock,
        RichBlock,
        VideoBlock,
        classifyMediaUrl,
        lostMediaUrls,
        normalizeAiMarkdown,
        AiNormalizeResult;
import '../models/item.dart';
import '../media/block_media.dart' show BlockMedia;
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
/// | update / delete / reprocess / unlock_edit / collect / append_segment / restore / set_vault(on) / set_pin | ✓ | ✓ | — |
/// | set_vault(off) 移出保险箱 | ✓（UI 无门禁）| ✗ 仅 ui actor 可 | — |
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
      final PinCommand c => _setPin(c, seeVault, txn),
      final ReclassifyCommand c => _reclassify(c, actor, seeVault, txn),
      final ReprocessCommand c => _reprocess(c, seeVault, txn),
      final AiSessionCommand c => _aiSession(c, seeVault, txn),
      final TranscribeCommand c => _transcribe(c, actor, seeVault, txn),
      final SummarizeCommand c => _summarize(c, actor, seeVault, txn),
      final ExtractTagsCommand c => _extractTags(c, seeVault, txn),
      final OcrCommand c => _ocr(c, actor, seeVault, txn),
      final ClassifyCommand c => _classify(c, seeVault, txn),
      final ScanBarcodeCommand c => _scanBarcode(c, seeVault, txn),
      final AnalyzeTextCommand c => _analyzeText(c, seeVault, txn),
      final ClipCommand c => _clip(c, seeVault, txn),
      final ClipProcessCommand c => _clipProcess(c, actor, seeVault, txn),
      final TranslateCommand c => _translate(c, actor, seeVault, txn),
      final ExtractAudioCommand c => _extractAudio(c, actor, seeVault, txn),
      final UnlockEditCommand c => _unlockEdit(c, seeVault, txn),
      final RestoreCommand c => _restore(c, seeVault, txn),
      final DeleteForeverCommand c => _deleteForever(c, txn),
      final SetAiVisibleCommand c => _setAiVisible(c, actor, seeVault, txn),
      final SetAiEditableCommand c => _setAiEditable(c, actor, seeVault, txn),
      final CollectCommand c => _collect(c, txn),
      final AppendSegmentCommand c => _append(c, actor, seeVault, txn),
        final ApplyAiResultCommand c => _applyAiResult(c, actor, seeVault, txn),
        final CreateWorkspaceCommand c => _createWorkspace(c),
        final RenameWorkspaceCommand c => _renameWorkspace(c),
        final DeleteWorkspaceCommand c => _deleteWorkspace(c, actor),
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
    _requireAiEditable(item, actor);
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
    // 待办勾选（UI 专属字段，fromJson 不解析——AI 不许翻用户的勾选本）：
    // null = 不动；空表 = 清空。写侧不做 GC（孤儿丢弃由 UI 组装全量时完成，
    // 动作层只认快照——防呆口径：层与层各守各的输入契约）。
    if (cmd.todoState != null) {
      values['todo_state_json'] = cmd.todoState!.isEmpty
          ? null
          : jsonEncode([for (final t in cmd.todoState!) t.toJson()]);
    }
    if (cmd.machineJson != null) {
      final err = validateMachineJson(cmd.machineJson);
      if (err != null) throw ActionException(err, code: ActionErrorCode.schemaInvalid);
      values['machine_json'] = cmd.machineJson;
    }
    if (cmd.itemType != null && cmd.itemType != item.itemType) {
      final err = _reclassifyError(item, cmd.itemType!,
          // 人工全放开（方向二拍板）：ui 与管线特权一致，仅 MCP AI 受白名单
          privilege: actor != CommandActor.ai);
      if (err != null) {
        throw ActionException(
          err,
          code: ActionErrorCode.reclassifyDenied,
          hint: 'AI 客户端仅允许 image→document（发票 / 文档截图）且须 source_type=image；人工端不设限（方向二拍板）',
        );
      }
      values['item_type'] = cmd.itemType;
    }
    if (values.isEmpty) throw ActionException('没有可更新的字段', code: ActionErrorCode.invalidRequest);
    await _write('update', cmd.id, values, expectedVersion: cmd.expectedVersion, txn: txn);
    // 编辑侧孤儿 GC（block-artifact-workflow.md §2.2 纪律 5/7）：human_md 变更时
    // diff 前后媒体行集合，被移除的块静默清产物（表行 + file_path 物理文件）。
    // 按路径寻址（纪律 6）：剪切粘贴 / 重排不改变 key 集合，不误杀；落点在动作层
    // 而非 serialize 纯函数（纯函数不识存储层）。复用防冲刷护城河的差集口径。
    if (cmd.humanMd != null && cmd.humanMd != (item.humanMd ?? '')) {
      for (final removed in lostMediaUrls(item.humanMd ?? '', cmd.humanMd!)) {
        await _repo.blockArtifacts.deleteBlock(cmd.id, removed, txn: txn);
      }
    }
    return _result('update', cmd.id, seeVault: seeVault, txn: txn, note: '已更新');
  }

  /// AI 编辑门禁（v20，ai-visibility）：外部 MCP AI（actor=ai）改写「人类编写」的笔记，
  /// 必须该笔记已开启「允许 AI 编辑」（ai_editable）。未授权直接拒绝（静态人类同意模型）。
  /// 端侧管线回写（actor=pipeline，如 OCR/翻译/摘要结果落盘）属 App 内部能力，不受此限。
  void _requireAiEditable(InboxItem item, CommandActor actor) {
    if (actor == CommandActor.ai &&
        item.author == InboxItem.authorHuman &&
        !item.aiEditable) {
      throw ActionException(
        '该笔记未授权 AI 编辑：人类笔记默认对 AI 只读，请在手机端开启「允许 AI 编辑」',
        code: ActionErrorCode.forbidden,
        hint: '在笔记详情开启「允许 AI 编辑」后，AI 方可修改此人类笔记',
      );
    }
  }

  // 「允许 AI 处理」（ai_process）门禁已整体移除（2026-10-05 拍板）：管线回写
  // 授权不再要独立开关——原 _requireAiProcess（apply_ai_result 拒写）与
  // _blockActorGate（块任务入队拒）删除；字段保留仅供历史数据兼容，UI 入口
  // 已随二级页开关一并删除。

  /// 切换「对 AI 可见」（v20，ai-visibility）。仅 UI（CommandActor.ui）可改：AI 既读不到
  /// ai_visible=0 的条目，也不得翻转此开关。人类笔记默认不可见，开启后 AI（MCP）方可读取。
  Future<CommandResult> _setAiVisible(
    SetAiVisibleCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    if (actor != CommandActor.ui) {
      throw ActionException(
        '「对 AI 可见」开关仅可在手机端修改',
        code: ActionErrorCode.forbidden,
        hint: 'AI 不得翻转可见性开关',
      );
    }
    await _require(cmd.id, seeVault: seeVault, txn: txn);
    await _write(
      'set_ai_visible',
      cmd.id,
      {'ai_visible': cmd.on ? 1 : 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    return _result('set_ai_visible', cmd.id, seeVault: seeVault, txn: txn,
        note: cmd.on ? '已对 AI 可见' : '已对 AI 隐藏');
  }

  /// 切换「允许 AI 编辑」（v20，ai-visibility）。仅 UI（CommandActor.ui）可改：即人类对 AI 的
  /// 静态同意。开启后，外部 MCP AI（actor=ai）方可改写该人类笔记（见 [_requireAiEditable]）。
  Future<CommandResult> _setAiEditable(
    SetAiEditableCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    if (actor != CommandActor.ui) {
      throw ActionException(
        '「允许 AI 编辑」开关仅可在手机端修改',
        code: ActionErrorCode.forbidden,
        hint: 'AI 不得翻转编辑授权开关',
      );
    }
    await _require(cmd.id, seeVault: seeVault, txn: txn);
    await _write(
      'set_ai_editable',
      cmd.id,
      {'ai_editable': cmd.on ? 1 : 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    return _result('set_ai_editable', cmd.id, seeVault: seeVault, txn: txn,
        note: cmd.on ? '已允许 AI 编辑' : '已收回 AI 编辑授权');
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
        hint: 'AI 只能移入（set_vault on=true）；移出须用户在手机端 UI 操作（actor=ui，无生物识别门禁）',
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

  /// 置顶 / 取消置顶（set_pin，schema v18）：pinned_at 写当前毫秒 / 置 NULL。
  /// 显示层能力，无隐私语义，UI 与 AI 同权（详见命令矩阵头注）。
  Future<CommandResult> _setPin(
    PinCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    if (!cmd.on && !item.isPinned) {
      throw ActionException('条目未置顶，无需取消', code: ActionErrorCode.invalidRequest);
    }
    await _write(
      'set_pin',
      cmd.id,
      {'pinned_at': cmd.on ? DateTime.now().millisecondsSinceEpoch : null},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    return _result(
      'set_pin',
      cmd.id,
      seeVault: seeVault,
      txn: txn,
      note: cmd.on ? '已置顶' : '已取消置顶',
    );
  }

  Future<CommandResult> _reclassify(
    ReclassifyCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final err = _reclassifyError(item, cmd.to,
        // 人工全放开（方向二拍板）：ui 与管线特权一致，仅 MCP AI 受白名单
        privilege: actor != CommandActor.ai);
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
    // 「重新处理」= 用户显式要求**用原文重做**：先把正文退回原文（旧 AI 产出
    // 作废），再入队等新产出。不重置的话，下游占位/降级回写（产出 = raw_content）
    // 会被 _applyAiResult 的「回填原文不覆盖现正文」保护挡住——重跑等于没跑，
    // 与既有口径「占位重跑覆盖旧产出」冲突。raw_content 为空时不重置，防清空。
    final reset = <String, Object?>{
      'is_processed': 0,
      if ((item.rawContent?.isNotEmpty ?? false) && item.humanMd != item.rawContent)
        'human_md': item.rawContent,
    };
    await _write(
      'reprocess',
      cmd.id,
      reset,
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
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final isBlock = cmd.blockKey != null;
    if (isBlock) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      await _blockMutexGuard(cmd.id, key, 'block_transcribe');
      final media = _blockMediaOf(item.bodyText, key, item: item);
      if (media.isImage ||
          (media.suffix != MediaSuffix.video &&
              media.suffix != MediaSuffix.audioPlayable &&
              media.suffix != MediaSuffix.audioDegrade)) {
        throw ActionException(
          '只有音 / 视频块能转写',
          code: ActionErrorCode.invalidRequest,
          hint: '图片块请用「识别文字」；该块类型不属音视频',
        );
      }
    } else if (item.itemType != InboxItem.typeAudio && item.itemType != InboxItem.typeVideo) {
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
    // 块任务不触碰条目状态（is_processed 是条目级处理位；产物在块级，条目字段零写）。
    if (!isBlock) {
      await _write(
        'transcribe',
        cmd.id,
        {'is_processed': 0},
        expectedVersion: cmd.expectedVersion,
        txn: txn,
      );
    }
    final action = isBlock
        ? Repository.blockTranscribeTaskAction(cmd.blockKey!, subtitleMode: mode, targetLang: lang)
        : Repository.transcribeTaskAction(subtitleMode: mode, targetLang: lang);
    final jobId = await _repo.enqueueTask(cmd.id, action, txn: txn);
    onEnqueued?.call();
    return _result('transcribe', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始转写'));
  }

  /// 行内视频块提取音轨（§2.4 block_extract_audio）：源为块视频文件，
  /// 产 audio_file 产物（文件落盘由重建器执行，file_path 落 block_artifacts）。
  /// 校验：块存在 + 视频后缀 + 门禁分叉 + 入队互斥（全部下沉，UI/MCP 同源）。
  Future<CommandResult> _extractAudio(
    ExtractAudioCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    _blockKeyGate(cmd.blockKey);
    await _blockMutexGuard(cmd.id, cmd.blockKey, 'block_extract_audio');
    final media = _blockMediaOf(item.bodyText, cmd.blockKey, item: item);
    if (media.isImage || media.suffix != MediaSuffix.video) {
      throw ActionException(
        '只有视频块能提取音轨',
        code: ActionErrorCode.invalidRequest,
        hint: '音频块本身即音轨无需提取；图片块无音轨',
      );
    }
    final jobId = await _repo.enqueueTask(
      cmd.id,
      Repository.blockExtractAudioTaskAction(cmd.blockKey),
      txn: txn,
    );
    onEnqueued?.call();
    return _result('extract_audio', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
        note: await _queuedNote('已开始提取音轨'));
  }

  /// 手动 OCR 图片：显式入队 ocr_and_extract（2026-09-28 用户拍板——分享摄入不默认
  /// OCR，只存文件；识别文字必须用户手动触发，与音频转写对称）。
  ///
  /// 「仅图片可 OCR」的校验下沉在动作层：AI / MCP 换个入口也绕不过。
  Future<CommandResult> _ocr(
    OcrCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final isBlock = cmd.blockKey != null;
    if (isBlock) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      await _blockMutexGuard(cmd.id, key, 'block_ocr');
      if (!_blockMediaOf(item.bodyText, key, item: item).isImage) {
        throw ActionException(
          '只有图片块能识别文字',
          code: ActionErrorCode.invalidRequest,
          hint: '音 / 视频块请用「转写」',
        );
      }
    } else if (item.itemType != InboxItem.typeImage) {
      throw ActionException(
        '只有图片能识别文字（当前类型：${item.itemType}）',
        code: ActionErrorCode.invalidRequest,
        hint: '音频 / 视频请点「转写」',
      );
    }
    // 块任务不触碰条目状态（is_processed 是条目级处理位；产物在块级）。
    if (!isBlock) {
      await _write(
        'ocr',
        cmd.id,
        {'is_processed': 0},
        expectedVersion: cmd.expectedVersion,
        txn: txn,
      );
    }
    final action =
        isBlock ? Repository.blockOcrTaskAction(cmd.blockKey!) : Repository.taskOcrAndExtract;
    final jobId = await _repo.enqueueTask(cmd.id, action, txn: txn);
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
    // 图片块分类（独立能力块级化 2026-10-05）：落 block_artifacts[classification]，
    // 条目级字段零触碰——顶级 'item' 与行内 local:// 同通道，统一处理口径
    //（块下仍校验图片源，缺文件由重建器明说，不静默）。
    if (cmd.blockKey != null) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      await _blockMutexGuard(cmd.id, key, 'block_classify');
      if (!_blockMediaOf(item.bodyText, key, item: item).isImage) {
        throw ActionException(
          '该块不是图片，无法分类（block_key=$key）',
          code: ActionErrorCode.invalidRequest,
        );
      }
      final jobId = await _repo.enqueueTask(
        cmd.id,
        Repository.blockClassifyTaskAction(key),
        txn: txn,
      );
      onEnqueued?.call();
      return _result('block_classify', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
          note: await _queuedNote('已开始识别分类'));
    }
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
    // 图片块条码（独立能力块级化 2026-10-05）：落 block_artifacts[barcode]，
    // 条目级字段零触碰——顶级 'item' 与行内 local:// 同通道，统一处理口径。
    if (cmd.blockKey != null) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      await _blockMutexGuard(cmd.id, key, 'block_scan_barcode');
      if (!_blockMediaOf(item.bodyText, key, item: item).isImage) {
        throw ActionException(
          '该块不是图片，无法扫描条码（block_key=$key）',
          code: ActionErrorCode.invalidRequest,
        );
      }
      final jobId = await _repo.enqueueTask(
        cmd.id,
        Repository.blockScanBarcodeTaskAction(key),
        txn: txn,
      );
      onEnqueued?.call();
      return _result('block_scan_barcode', cmd.id, seeVault: seeVault, txn: txn, jobId: jobId,
          note: await _queuedNote('已开始识别条码'));
    }
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
  ///
  /// 块级切片（2026-10-05）：行内音 / 视频块（local:// key）按**块类型**校验——
  /// 块媒体行是音 / 视频即可切片，不再继承条目 itemType（笔记里的音视频块不是
  /// 死项）；顶级 'item' 哨兵与无 blockKey 同走条目级。标记不触发处理，
  /// 无入队故不挂互斥。
  Future<CommandResult> _clip(
    ClipCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final isBlockClip =
        cmd.blockKey != null && cmd.blockKey != BlockArtifactKind.topLevelKey;
    if (isBlockClip) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      final media = _blockMediaOf(item.bodyText, key, item: item);
      if (media.isImage ||
          (media.suffix != MediaSuffix.video &&
              media.suffix != MediaSuffix.audioPlayable &&
              media.suffix != MediaSuffix.audioDegrade)) {
        throw ActionException(
          '只有音 / 视频块能切片',
          code: ActionErrorCode.invalidRequest,
          hint: '图片 / 链接 / 文档块无媒体时间轴',
        );
      }
    } else if (item.itemType != InboxItem.typeVideo &&
        item.itemType != InboxItem.typeAudio) {
      throw ActionException(
        '只有音 / 视频能切片（当前类型：${item.itemType}）',
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
    if (clips.any((c) =>
        c.blockKey == (isBlockClip ? cmd.blockKey : null) &&
        c.startMs == cmd.startMs &&
        c.endMs == cmd.endMs)) {
      throw ActionException(
        '该区间已存在',
        code: ActionErrorCode.invalidRequest,
        hint: '可在切片列表里查看已有区间',
      );
    }
    final updated = [
      ...clips,
      ClipSegment(
        startMs: cmd.startMs,
        endMs: cmd.endMs,
        blockKey: isBlockClip ? cmd.blockKey : null,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
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
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final isBlock = cmd.blockKey != null;
    if (isBlock) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      await _blockMutexGuard(cmd.id, key, 'block_translate');
      final src = cmd.sourceKind?.trim() ?? '';
      if (!const {
        BlockArtifactKind.transcript,
        BlockArtifactKind.ocrText,
        BlockArtifactKind.subtitle,
      }.contains(src)) {
        throw ActionException(
          '块翻译需要 source_kind（transcript / ocr_text / subtitle 之一）',
          code: ActionErrorCode.invalidRequest,
        );
      }
      final srcArtifact = await _repo.blockArtifacts.get(cmd.id, key, src, txn: txn);
      if (srcArtifact == null || (srcArtifact.text?.trim().isEmpty ?? true)) {
        throw ActionException(
          '源产物「$src」不存在或为空，无法翻译',
          code: ActionErrorCode.invalidRequest,
          hint: '先执行「转写」/「识别文字」产出源文本',
        );
      }
    } else if (item.bodyText.trim().isEmpty) {
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
    if (!isBlock) {
      await _write(
        'translate',
        cmd.id,
        {'is_processed': 0},
        expectedVersion: cmd.expectedVersion,
        txn: txn,
      );
    }
    final action = isBlock
        ? Repository.blockTranslateTaskAction(
            cmd.blockKey!,
            targetLang: lang,
            sourceKind: cmd.sourceKind!,
          )
        : Repository.translateTaskAction(lang);
    final jobId = await _repo.enqueueTask(cmd.id, action, txn: txn);
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
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final isBlock = cmd.blockKey != null;
    if (isBlock) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      await _blockMutexGuard(cmd.id, key, 'block_summarize');
      final hasSource = await _blockHasArtifact(cmd.id, key, const {
        BlockArtifactKind.transcript,
        BlockArtifactKind.ocrText,
      }, txn: txn);
      if (!hasSource) {
        throw ActionException(
          '该块还没有可摘要的文本产物',
          code: ActionErrorCode.invalidRequest,
          hint: '先执行「转写」或「识别文字」产出源文本',
        );
      }
    } else if (item.bodyText.trim().isEmpty) {
      throw ActionException(
        '该条目没有可摘要的正文',
        code: ActionErrorCode.invalidRequest,
        hint: '图片 / 音视频请先「识别文字」或「转写」出文本，再摘要',
      );
    }
    if (!isBlock) {
      await _write(
        'summarize',
        cmd.id,
        {'is_processed': 0},
        expectedVersion: cmd.expectedVersion,
        txn: txn,
      );
    }
    final action =
        isBlock ? Repository.blockSummarizeTaskAction(cmd.blockKey!) : Repository.taskLlmSummarize;
    final jobId = await _repo.enqueueTask(cmd.id, action, txn: txn);
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
        author: cmd.author,
        // AI 建条默认对 AI 可见且可编辑；人类收集默认对 AI 不可见、不可编辑（静态同意模型）。
        aiVisible: cmd.author == InboxItem.authorAi,
        aiEditable: cmd.author == InboxItem.authorAi,
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
  Future<CommandResult> _append(
    AppendSegmentCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final text = cmd.text.trim();
    if (text.isEmpty) {
      throw ActionException('追加文本不能为空', code: ActionErrorCode.invalidRequest);
    }
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    _requireAiEditable(item, actor);
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
  ///
  /// 块级切片（2026-10-05）：行内视频块入队 `block_clip:<key>|<s>-<e>|<steps>`
  ///（块类型校验 + §2.6 授权门禁 + §6.6 入队互斥同其他块动作）；区间存在性
  /// 按 blockKey 定位，与条目级切片互不可见。
  Future<CommandResult> _clipProcess(
    ClipProcessCommand cmd,
    CommandActor actor,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final isBlockClip =
        cmd.blockKey != null && cmd.blockKey != BlockArtifactKind.topLevelKey;
    if (isBlockClip) {
      final key = cmd.blockKey!;
      _blockKeyGate(key);
      await _blockMutexGuard(cmd.id, key, 'block_clip');
      final media = _blockMediaOf(item.bodyText, key, item: item);
      if (media.isImage ||
          (media.suffix != MediaSuffix.video &&
              media.suffix != MediaSuffix.audioPlayable &&
              media.suffix != MediaSuffix.audioDegrade)) {
        throw ActionException(
          '只有音 / 视频块能切片处理',
          code: ActionErrorCode.invalidRequest,
          hint: '图片 / 链接 / 文档块无媒体时间轴',
        );
      }
    } else if (item.itemType != InboxItem.typeVideo &&
        item.itemType != InboxItem.typeAudio) {
      throw ActionException(
        '只有音 / 视频能切片处理（当前类型：${item.itemType}）',
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
    final idx = clips.indexWhere((c) =>
        c.blockKey == (isBlockClip ? cmd.blockKey : null) &&
        c.startMs == cmd.startMs &&
        c.endMs == cmd.endMs);
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
    final action = isBlockClip
        ? Repository.blockClipTaskAction(cmd.blockKey!, cmd.startMs, cmd.endMs, steps)
        : Repository.clipTaskAction(cmd.startMs, cmd.endMs, steps);
    final jobId = await _repo.enqueueTask(cmd.id, action, txn: txn);
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
    // 块附件通道产出（block-artifact-workflow.md §2.5 回写分叉）：单事务 upsert
    // 进 block_artifacts（转写 transcript+subtitle 双产物原子落库），条目级字段
    // **零触碰**——不写 human_md / is_processed，块任务不标条目处理位。
    // 空载荷 = 无产出（失败 / 占位），原因已在 r.note（R1），直接透传。
    if (r.blockKey != null) {
      final arts = r.blockArtifacts;
      if (arts != null && arts.isNotEmpty) {
        await _repo.blockArtifacts.upsertAll(cmd.id, r.blockKey!, arts, txn: txn);
      }
      return _result('apply_ai_result', cmd.id, seeVault: seeVault, txn: txn,
          note: r.note ??
              (arts == null || arts.isEmpty ? '块任务完成但无产出' : '已写入块产物'));
    }
    // 防冲刷护城河（2026-09-30 拍板叮嘱②）：AI 产出的 human_md 若丢失原文的
    // 行内媒体块，说明模型删了用户资产——human_md 保留原文（其余字段照常应用），
    // 原因进 result.note 可感知（R1）。只拦管线回写；UI/MCP update 走块编辑器，
    // 用户手动删媒体是合法操作。
    final lostMedia = lostMediaUrls(item.humanMd ?? '', r.humanMd);
    final guarded = lostMedia.isNotEmpty;
    // AI 写入归一层（rich-text-gfm.md §2 层2）：全集外语法语义映射 + R1 note；
    // 全集内语法零映射透传。guarded（丢媒体）时保留原文，归一让位给护城河。
    final normalized = guarded
        ? const AiNormalizeResult('', [])
        : normalizeAiMarkdown(r.humanMd);
    final incoming = guarded ? (item.humanMd ?? '') : normalized.markdown;
    // AI 回写不得把正文**静默打回**最初摄入的 raw_content（2026-10-04）：
    // 占位实现（PlaceholderReconstructor）与队列超时兜底一律把产出 humanMd
    // 填成 input.rawContent，直接落库会覆盖用户在详情页编辑保存过的正文——
    // 丢内容也丢行内样式（表现即「编辑态有下划线、详情读态没有」：两态读的
    // 都是 bodyText，只是被回填换了份旧的）。
    // 判据：产出与 raw_content 逐字符相同 = 本次没有新正文 → 保留条目现
    // human_md。显式「重新处理」由 _reprocess 先把正文重置回原文，不受此保护
    // 影响（既有口径：占位重跑必须覆盖旧产出）。
    final rawEcho = incoming == (item.rawContent ?? '');
    final keepHuman = (item.humanMd?.isNotEmpty ?? false) && rawEcho;
    final values = <String, Object?>{
      if (!keepHuman) 'human_md': incoming,
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
    // AI 会话（ai-writeback-revert）：**管线写回不再触发会话**（2026-10-05 拍板）——
    // 不锚基线、不进 pending，详情页不再挂「AI 已改写这篇」悬浮条；产出仍落
    // ai_revisions（历史面板可找回）。已存在的未关闭会话态原样保留，不覆盖。
    final aiApplied = !guarded && r.humanMd.isNotEmpty && !keepHuman;
    final mergedDocMeta = <String, Object?>{
      if (item.docMetaJson != null) ...?_decodeDocMeta(item.docMetaJson),
      if (r.docMetaJson != null) ...?_decodeDocMeta(r.docMetaJson),
      if (item.aiSessionState != null) 'ai_session_state': item.aiSessionState!,
    };
    values['doc_meta_json'] = jsonEncode(mergedDocMeta);
    // 本次 AI 产出的人类态快照（用于 ai_revisions 落库）。
    final revisionSnapshot = aiApplied ? (values['human_md'] as String?) : null;

    Future<void> doWrite(Transaction t) async {
      await _write('apply_ai_result', cmd.id, values,
          expectedVersion: cmd.expectedVersion, txn: t);
      if (revisionSnapshot != null) {
        await _repo.insertAiRevision(
          cmd.id,
          revisionSnapshot,
          source: 'ai_writeback',
          metaJson: r.docMetaJson,
          txn: t,
        );
      }
    }

    if (txn != null) {
      await doWrite(txn);
    } else {
      await _repo.transaction(doWrite);
    }
    return _result('apply_ai_result', cmd.id, seeVault: seeVault, txn: txn,
        note: guarded
            ? 'AI 产出丢失行内媒体块（${lostMedia.length} 个），已保留原文；其余字段照常回写'
            : (normalized.notes.isNotEmpty
                ? '${normalized.notes.join('；')}；已回写 AI 产出'
                : '已回写 AI 产出'));
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

  /// 删除工作区（docs/design/workspace.md §3.2 拍板 B：非空守门下沉动作层，
  /// UI/MCP/AI 同口径）。计数与工作区列表同口径——排除 Vault 与已删，
  /// 不泄露保险箱条目数（工作区不得成为隐私隔离后门）。
  Future<CommandResult> _deleteWorkspace(
    DeleteWorkspaceCommand cmd,
    CommandActor actor,
  ) async {
    final existing = await _repo.byIdWorkspace(cmd.workspaceId);
    if (existing == null) {
      throw ActionException(
        '工作区不存在：id=${cmd.workspaceId}',
        code: ActionErrorCode.notFound,
        hint: '先执行 list_workspaces 确认 id',
      );
    }
    final count = (await _repo.listWorkspaceItems(cmd.workspaceId)).length;
    if (count > 0 && !cmd.ackNonEmpty) {
      throw ActionException(
        '工作区「${existing.name}」还有 $count 条内容，删除被拦下',
        code: ActionErrorCode.invalidRequest,
        hint: '删除工作区只解除归属，条目保留在「全部」；非空删除须人类在'
            '手机端工作区卡长按弹层确认（明示条数），AI 端不可代删非空工作区',
      );
    }
    if (count > 0 && actor != CommandActor.ui) {
      throw ActionException(
        '非空工作区删除的确认仅人类 UI 可给',
        code: ActionErrorCode.forbidden,
        hint: '与用户确认后引导其在手机端删除，或先移空归属再来删除',
      );
    }
    await _repo.deleteWorkspace(cmd.workspaceId);
    return CommandResult(
      op: 'delete_workspace',
      targetId: cmd.workspaceId,
      note: count > 0
          ? '已删除工作区「${existing.name}」，$count 条内容保留在「全部」'
          : '已删除工作区「${existing.name}」',
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

  // ---- 块附件通道校验（block-artifact-workflow.md §6；UI/MCP 同源绕不过）----

  /// §6.1 blockKey 格式防呆：`local://` 开头且不含分段符 `|`——防伪造 key
  /// 下滑到文件路径拼接（重建器按 key 解析物理路径）。
  void _blockKeyGate(String key) {
    // 顶级条目统一（block-artifact-workflow.md §2.7）：item = 顶级媒体区的
    // 固定 key，与行内 `local://` 媒体行同走块通道；其余 key 仍须是正文媒体行。
    if (key == BlockArtifactKind.topLevelKey) return;
    if (!key.startsWith('local://') || key.length <= 'local://'.length || key.contains('|')) {
      throw ActionException(
        'block_key 非法：须为正文媒体行的 local:// 路径',
        code: ActionErrorCode.invalidRequest,
        hint: 'block_key 取自 human_md 媒体行 url，逐字相等（不含行号 / 序号）',
      );
    }
  }

  // §2.6 门禁分叉已随「允许 AI 处理」开关一并移除（2026-10-05 拍板）：
  // 原 _blockActorGate（AI/MCP 发起块任务须 aiProcess）删除——块任务产物
  // 落 block_artifacts、不触碰条目 human_md，授权统一收口到「允许 AI 编辑」。

  /// §6.6 入队互斥：同 (item, 动作头, blockKey) 已有 pending/processing 任务
  /// 即拒绝——防模型连发/双击重复入队刷长任务（执行侧 FIFO 串行本无并发）。
  /// 参数差异（mode/lang 不同）同样拒绝：换参数语义由取消 / Reset 承载。
  Future<void> _blockMutexGuard(String itemId, String blockKey, String head) async {
    for (final action in await _repo.activeBlockActionsOf(itemId)) {
      final parsed = Repository.parseBlockAction(action);
      if (parsed != null && parsed.$1 == head && parsed.$2 == blockKey) {
        throw ActionException(
          '该块的「$head」任务已在队列中，等待完成即可',
          code: ActionErrorCode.invalidRequest,
          hint: '同块同任务不重复入队；换参数请先在任务队列取消原任务',
        );
      }
    }
  }

  /// §6.1 块媒体行校验：human_md 中**确有**该 block_key 的媒体行（防伪造 key），
  /// 同时给出块类型与后缀归类（转写=音视后缀 / OCR=图片块 / 提取音轨=视频后缀）。
  /// 引用块内的媒体行同样有效（QuoteBlock 递归）。
  BlockMedia _blockMediaOf(String humanMd, String blockKey, {InboxItem? item}) {
    // 顶级条目统一（§2.7）：block_key='item' 的媒体源就是条目本身的
    // rawFilePath（顶级媒体区没有正文媒体行可扫），类型由 item_type 判定。
    // 图片条目同走块通道（2026-10-05 修：工作流页 OCR/翻译/摘要 + 分类/条码
    // 独立能力与行内图片块同一入口，不放行即全数被拒的断链）。
    if (blockKey == BlockArtifactKind.topLevelKey) {
      final type = item?.itemType ?? '';
      if (type == InboxItem.typeImage) {
        return BlockMedia(
          url: blockKey,
          isImage: true,
          suffix: MediaSuffix.unknown,
        );
      }
      if (type == InboxItem.typeVideo || type == InboxItem.typeAudio) {
        return BlockMedia(
          url: blockKey,
          isImage: false,
          suffix: type == InboxItem.typeVideo
              ? MediaSuffix.video
              : MediaSuffix.audioPlayable,
        );
      }
      throw ActionException(
        '顶级条目不是音 / 视频类型，无块媒体可处理',
        code: ActionErrorCode.invalidRequest,
      );
    }
    final blocks = const MarkdownSubsetParser().parse(humanMd);

    BlockMedia? scan(Iterable<RichBlock> bs) {
      for (final b in bs) {
        if (b is ImageBlock && b.url == blockKey) {
          return BlockMedia(url: b.url, isImage: true, suffix: MediaSuffix.unknown);
        }
        if (b is AudioBlock && b.url == blockKey) {
          return BlockMedia(url: b.url, isImage: false, suffix: classifyMediaUrl(b.url));
        }
        if (b is VideoBlock && b.url == blockKey) {
          return BlockMedia(url: b.url, isImage: false, suffix: classifyMediaUrl(b.url));
        }
        if (b is QuoteBlock) {
          final inner = scan(b.children);
          if (inner != null) return inner;
        }
      }
      return null;
    }

    final found = scan(blocks);
    if (found == null) {
      throw ActionException(
        '正文中不存在该媒体行，无法执行块能力',
        code: ActionErrorCode.notFound,
        hint: 'block_key 必须逐字等于 human_md 中某个媒体行的 local:// 路径'
            '（媒体行可能已被编辑移除）',
      );
    }
    return found;
  }

  /// §6.2 源产物存在性：该 (item, block) 下 kinds 任一存在且文本非空。
  Future<bool> _blockHasArtifact(
    String itemId,
    String blockKey,
    Set<String> kinds, {
    Transaction? txn,
  }) async {
    for (final k in kinds) {
      final a = await _repo.blockArtifacts.get(itemId, blockKey, k, txn: txn);
      if (a != null && (a.text?.trim().isNotEmpty ?? false)) return true;
    }
    return false;
  }

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
      // AI 写回会话态（还原/恢复/接管）是**人类侧的撤销工具**：AI 不得自行
      // 声明会话已关闭，否则可一键抹掉人类的还原权（ai-writeback-revert §4）。
      AiSessionCommand() => actor == CommandActor.ui,
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
    // 主体三分（2026-10-05 拍板「方向二」）：
    // - **管线**（AI 回写）特权全放——既有口径；
    // - **人工（ui）全放开**——类型与标签同属用户权威元数据（HCI 同构：
    //   AI 提取代劳不是权威），误判纠错出口给全；渲染/管线的形态变化由
    //   UI 确认弹窗文案承担（媒体→文本明示附件不再显示），动作层不禁死；
    // - **AI 客户端（MCP）维持窄白名单**——防大模型乱改类型（白名单的由来）。
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

  /// 解析 doc_meta_json（坏 JSON 返回 null），供 AI 写回时合并 ai_session_state 用。
  Map<String, Object?>? _decodeDocMeta(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final d = jsonDecode(raw);
      return d is Map ? d.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// AI 写回会话态变更（ai-writeback-revert §4/§5/§8.3）：还原 / 恢复 AI 改动 /
  /// 接管闭环。三态各自的不变量在此强制——UI 换入口、AI 换传输层都绕不过。
  Future<CommandResult> _aiSession(
    AiSessionCommand cmd,
    bool seeVault,
    Transaction? txn,
  ) async {
    final item = await _require(cmd.id, seeVault: seeVault, txn: txn);
    final baseline = item.humanMdBaseline;
    final values = <String, Object?>{};
    late final String note;
    switch (cmd.phase) {
      case AiSessionPhase.restored:
        // 还原：human_md ← 基线（AI 动笔前）。基线非空才有得还原（§3.1）。
        if (baseline == null || baseline.isEmpty) {
          throw ActionException(
            '没有可还原的 AI 改动',
            code: ActionErrorCode.invalidRequest,
            hint: '该条目没有未关闭的 AI 会话（基线为空），无需还原',
          );
        }
        values['human_md'] = baseline;
        note = '已还原到 AI 动笔前';
      case AiSessionPhase.pending:
        // 恢复 AI 改动：human_md ← ai_revisions 最新条（§3.2 恢复源不在 Meta）。
        if (baseline == null || baseline.isEmpty) {
          throw ActionException(
            '没有可恢复的 AI 改动',
            code: ActionErrorCode.invalidRequest,
            hint: '该条目没有未关闭的 AI 会话（基线为空）',
          );
        }
        final ai = cmd.humanMd ?? await _repo.latestAiRevision(cmd.id, txn: txn);
        if (ai == null || ai.isEmpty) {
          throw ActionException(
            'AI 版本已不可恢复',
            code: ActionErrorCode.invalidRequest,
            hint: 'ai_revisions 里没有该条目的快照，无法换回 AI 版',
          );
        }
        values['human_md'] = ai;
        note = '已恢复 AI 改动';
      case AiSessionPhase.idle:
        // 接管闭环（§5）：基线置 null、会话关闭；当前文本一并落库（§8.3：
        // flush 必须同时提交文本与状态翻转，否则重开后文本是手改版却仍挂
        // 悬浮条）。被放弃的 AI 版此前已由 apply_ai_result 追加进
        // ai_revisions（§5 步骤 1 的持久留痕在此成立），故不重复写。
        values['human_md_baseline'] = null;
        if (cmd.humanMd != null) values['human_md'] = cmd.humanMd;
        note = '已切换手动编辑';
    }
    values['doc_meta_json'] = jsonEncode(<String, Object?>{
      if (item.docMetaJson != null) ...?_decodeDocMeta(item.docMetaJson),
      'ai_session_state': cmd.phase.name,
    });
    await _write(
      'ai_session',
      cmd.id,
      values,
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    return _result('ai_session', cmd.id, seeVault: seeVault, txn: txn, note: note);
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
