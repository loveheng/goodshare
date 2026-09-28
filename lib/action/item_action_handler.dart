import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../data/repository.dart';
import '../models/item.dart';
import 'commands.dart';
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
      final OcrCommand c => _ocr(c, seeVault, txn),
      final UnlockEditCommand c => _unlockEdit(c, seeVault, txn),
      final RestoreCommand c => _restore(c, seeVault, txn),
      final DeleteForeverCommand c => _deleteForever(c, txn),
      final CollectCommand c => _collect(c, txn),
      final AppendSegmentCommand c => _append(c, seeVault, txn),
        final ApplyAiResultCommand c => _applyAiResult(c, actor, seeVault, txn),
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
          hint: '人工/AI 客户端仅允许 image→chatlog / document，且须 source_type=image',
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
        hint: '可选目标：${InboxItem.typeChatlog} / ${InboxItem.typeDocument}',
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
    await _repo.enqueueTask(cmd.id, action, txn: txn);
    onEnqueued?.call();
    return _result('reprocess', cmd.id, seeVault: seeVault, txn: txn, note: '已重新入队');
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
    await _write(
      'transcribe',
      cmd.id,
      {'is_processed': 0},
      expectedVersion: cmd.expectedVersion,
      txn: txn,
    );
    await _repo.enqueueTask(cmd.id, Repository.taskTranscribeAudio, txn: txn);
    onEnqueued?.call();
    return _result('transcribe', cmd.id, seeVault: seeVault, txn: txn,
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
    await _repo.enqueueTask(cmd.id, Repository.taskOcrAndExtract, txn: txn);
    onEnqueued?.call();
    return _result('ocr', cmd.id, seeVault: seeVault, txn: txn,
        note: await _queuedNote('已开始识别文字'));
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
        // 合并链：新链即锁定（须先「解除编辑」），首段同样记入 appendix（设计 §4.9）
        editLocked: merge,
        appendix: merge && cmd.rawContent != null
            ? [AppendixEntry(ts: now, text: cmd.rawContent!, source: cmd.sourceApp)]
            : const [],
        createdAt: now,
      ),
      txn: txn,
    );
    await _repo.enqueueTask(item.id!, Repository.taskActionFor(item.itemType), txn: txn);
    return CommandResult(op: 'collect', targetId: item.id, item: item, note: '已收集');
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
    await _repo.enqueueTask(cmd.id, Repository.taskActionFor(item.itemType), txn: txn);
    return _result('append_segment', cmd.id, seeVault: seeVault, txn: txn, note: '已追加到合并链');
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
    final values = <String, Object?>{'human_md': r.humanMd, 'is_processed': 1};
    if (r.machineJson != null) {
      final raw = jsonEncode(r.machineJson);
      final err = validateMachineJson(raw);
      if (err != null) {
        throw ActionException('AI 产出 machine_json 校验不过：$err', code: ActionErrorCode.schemaInvalid);
      }
      values['machine_json'] = raw;
    }
    if (r.tags.isNotEmpty) values['tags'] = jsonEncode(r.tags);
    if (r.itemType != null && r.itemType != item.itemType) {
      if (actor != CommandActor.pipeline) {
        final err = _reclassifyError(item, r.itemType!, privilege: false);
        if (err != null) throw ActionException(err, code: ActionErrorCode.reclassifyDenied);
      }
      values['item_type'] = r.itemType;
    }
    if (r.facets != null) values['facets_json'] = jsonEncode(r.facets);
    await _write('apply_ai_result', cmd.id, values, expectedVersion: cmd.expectedVersion, txn: txn);
    return _result('apply_ai_result', cmd.id, seeVault: seeVault, txn: txn, note: '已回写 AI 产出');
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
    if (to != InboxItem.typeChatlog && to != InboxItem.typeDocument) {
      return '仅允许 image→chatlog / document';
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
  }) async {
    final fresh = await _repo.byId(id, includeDeleted: true, includeVault: true, txn: txn);
    if (fresh == null) return CommandResult(op: op, targetId: id, note: note);
    final visible = seeVault || !fresh.isVault;
    return CommandResult(op: op, targetId: id, item: visible ? fresh : null, note: note);
  }
}
