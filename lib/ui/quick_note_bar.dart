import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';

import '../action/commands.dart';
import '../action/item_action_handler.dart';
import '../doc/rich_text.dart' show MediaSuffix, classifyMediaUrl;
import '../models/item.dart';
import '../share/attachments.dart';
import '../share/note_composer.dart';
import '../share/note_video_policy.dart';
import '../share/text_collector.dart';
import 'audio_playback_service.dart';
import 'goodshare_image.dart';
import 'media_blocks.dart';
import 'note_video_capture_page.dart';
import 'tokens.dart';

/// 底部常驻速记条（2026-09-29 改版：取代悬浮球）。
///
/// 硬要求：速记路径**不得比原悬浮球更长**——点即聚焦、打字即存。
///
/// 2026-09-30 多媒体改版（用户拍板「便签页多媒体编辑，媒体不分散保存」）：
/// - 文本层升级为**分段作曲器**：拍照 / 相册图 / 录音在**光标处就地插入**为媒体卡，
///   文字—图—录音混排；保存时整体序列化为**一个** note 条目（媒体不另立卡片）；
/// - **工具语义反转**：拍照/录音不再是「直接出独立卡片」的旁路出口，而是插入本条
///   ——独立媒体条目走顶部 `＋` 菜单（ui-spec §4.6）；
/// - **含媒体便签豁免合并窗口**（用户拍板）：纯文本仍走 TextCollector（合并逻辑
///   不变），含媒体直发 CollectCommand 独立成条（序列化见 note_composer.dart）。
///
/// 其余沿用前轮拍板：
/// - **收合态**：只露顶边的便签拉手，上滑/点按拽出；
/// - **展开态**：接近整屏的书写面板——顶栏「收起箭头 · 今日日期 · 保存」，
///   主体大书写区（左右仅小边距，靠投影分层），下方两行工具
///   「标题 / 粗体」+「拍照 / 相册 / 录音 / 标签 / 待办」；
/// - **保存语义**：点保存 = 生成新卡片并**清空内容区**（面板不关，可连续记）；
///   **不点保存内容就留在便签里**（收合/切 tab 均保留，静态草稿缓存，含媒体段）。
class QuickNoteBar extends StatefulWidget {
  const QuickNoteBar({
    super.key,
    required this.collector,
    required this.handler,
  });

  final TextCollector collector;
  final ItemActionHandler handler;

  @override
  State<QuickNoteBar> createState() => _QuickNoteBarState();
}

/// 段：文本或行内媒体（作曲器的最小单元）。
sealed class _Seg {}

class _TextSeg extends _Seg {
  _TextSeg([String text = ''])
    : ctrl = TextEditingController(text: text),
      focus = FocusNode();

  final TextEditingController ctrl;
  final FocusNode focus;
  final GlobalKey key = GlobalKey();

  void dispose() {
    ctrl.dispose();
    focus.dispose();
  }
}

class _MediaSeg extends _Seg {
  _MediaSeg(this.url, {required this.kind});

  /// 行内媒体 url（`local://` 相对标记，SSOT：rich-text-media.md §2——
  /// 绝不写绝对路径，iOS 沙盒路径会变；IO/渲染经 [resolveLocalMediaSrc] 解析）。
  final String url;

  /// 媒体类别：图片 / 录音 / 视频（便签内嵌视频附件态，2026-10-01 拍板）。
  final NoteMediaKind kind;

  /// 本体文件（渲染预览与删除清理共用同一解析口）。
  File get file => File(resolveLocalMediaSrc(url));
}

enum NoteMediaKind { image, audio, video }

/// 视频来源二选一（note-video.md §1）。
enum _VideoSource { album, camera }

class _QuickNoteBarState extends State<QuickNoteBar> {
  final _recorder = AudioRecorder();

  /// 作曲器段序列（首段恒为文本；媒体段之后恒有文本段，保证可继续书写）。
  final List<_Seg> _segs = [_TextSeg()];

  /// 便利贴作用域的音频播放服务：媒体卡复用 [MediaAudioBar]，但**不**自持
  /// AudioPlayer（单实例红线，与详情页同一服务机制，仅作用域不同）。
  final AudioPlaybackController _audioCtl = AudioPlaybackController();

  // 草稿静态留存：跨「收合 / 切 tab / 面板销毁」与 Activity 重建幸存
  // （用户拍板：没点保存就留在便签里）。行编码 ['t',文本] / ['i',图路径] / ['a',音路径]。
  static List<List<String>> _draftSegsPersisted = const [];

  // 面板态静态留存：系统相机/权限弹窗可能重建 Activity，普通字段归零而这些幸存
  // （与草稿同口径，2026-09-30 修「点拍照回来便签消失」）。
  static bool _expandedPersisted = false;
  static List<String> _pendingTagsPersisted = [];
  static bool _todoModePersisted = false;

  /// 本条未保存内容上挂的标签（标签按钮设置，随保存落库，保存后清空）。
  List<String> _pendingTags = [];

  /// 待办模式：开 = 保存时文本段逐行转 `- [ ]` 待办。
  bool _todoMode = false;

  bool _recording = false;
  bool _sending = false;
  bool _expanded = false;

  /// 相册长视频「仍要添加」确认后暂存的落盘路径（>5min 非阻断流专用，
  /// 确认弹窗与插入之间不留其他异步窗口）。
  String? _pendingVideoPath;

  /// 收合↔展开的连续形变进度（0 = 收合拉手，1 = 满幅面板）。
  /// 方案 A（用户拍板「跟手渐展」）：上滑直接控面板高度，头部+身体一起长出；
  /// 拖动中 progress 实时跟手，松手过阈值补间到 1、未过补间回 0。
  /// _expanded 仅作为「进度到 1 后的稳定态」（焦点/草稿等副作用仍挂在它上面）。
  double _progress = 0;
  bool _dragSettling = false;

  /// 拖动期间禁用内容裁剪/淡入的阈值以下仍显示整块内容。
  static const double _contentFadeStart = 0.35;

  /// 收合态露出高度（便签顶边拉手）。
  static const double _peekHeight = 52;

  /// 工具层固定高度（格式行 + 动作行，两行图标）。文本层的滚动视口底边按它
  /// 上移让位——改这里必须同步考虑光标让位（文本层视口 Padding）。
  static const double _toolLayerHeight = 96;

  @override
  void initState() {
    super.initState();
    // 恢复未保存草稿（含媒体段）；空草稿起手一段文本
    if (_draftSegsPersisted.isNotEmpty) {
      _segs
        ..clear()
        ..addAll([
          for (final row in _draftSegsPersisted)
            switch (row.first) {
              'i' => _MediaSeg(
                row[1],
                kind: NoteMediaKind.image,
              ), // row[1] = local:// url
              'a' => _MediaSeg(row[1], kind: NoteMediaKind.audio),
              'v' => _MediaSeg(row[1], kind: NoteMediaKind.video),
              _ => _TextSeg(row.length > 1 ? row[1] : ''),
            },
        ]);
    }
    _ensureTrailingText();
    // 系统相机/权限弹窗可能重建 Activity（内存回收）：导航栈原样恢复，但普通字段
    // 全部归零——静态字段与草稿同口径幸存，面板与草稿一起恢复。
    _expanded = _expandedPersisted;
    _progress = _expanded ? 1 : 0; // 形变进度与展开态同源恢复，防「态开形未开」
    _pendingTags = List.of(_pendingTagsPersisted);
    _todoMode = _todoModePersisted;
  }

  @override
  void dispose() {
    _expandedPersisted = _expanded;
    _pendingTagsPersisted = List.of(_pendingTags);
    _todoModePersisted = _todoMode;
    _persistDraft();
    for (final s in _segs) {
      if (s is _TextSeg) s.dispose();
    }
    _audioCtl.dispose();
    _recorder.dispose();
    super.dispose();
  }

  /// 当前草稿序列化进静态缓存（变更点同步：Activity 重建不一定走 dispose）。
  void _persistDraft() {
    _draftSegsPersisted = [
      for (final s in _segs)
        switch (s) {
          _TextSeg(:final ctrl) => ['t', ctrl.text],
          _MediaSeg(:final url, kind: NoteMediaKind.image) => ['i', url],
          _MediaSeg(:final url, kind: NoteMediaKind.audio) => ['a', url],
          _MediaSeg(:final url, kind: NoteMediaKind.video) => ['v', url],
        },
    ];
  }

  /// 不变量：媒体段之后恒有文本段（用户在媒体后继续书写）。
  void _ensureTrailingText() {
    if (_segs.isEmpty || _segs.last is _MediaSeg) _segs.add(_TextSeg());
  }

  /// 便签是否“有东西可存”（文字/媒体/待挂标签/待办模式任一）——
  /// 保存按钮的内容感知点亮依据。
  bool get _hasContent =>
      _pendingTags.isNotEmpty ||
      _todoMode ||
      _segs.any(
        (s) =>
            s is _MediaSeg || (s is _TextSeg && s.ctrl.text.trim().isNotEmpty),
      );

  String get _todayLabel {
    final now = DateTime.now();
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return '${now.year}年${now.month}月${now.day}日 ${weekdays[now.weekday - 1]}';
  }

  /// 焦点所在文本段；无焦点回退最后一段文本（拍完照回来焦点归零的常态）。
  _TextSeg? get _activeText {
    var idx = _segs.indexWhere((s) => s is _TextSeg && s.focus.hasFocus);
    if (idx < 0) {
      idx = _segs.lastIndexWhere((s) => s is _TextSeg);
      if (idx < 0) return null;
    }
    return _segs[idx] as _TextSeg;
  }

  /// 把媒体插入到光标处：焦点文本段按光标位拆成两段，媒体卡居中。
  /// 无焦点则挂到末尾。插入后焦点落到媒体后的文本段（光标在段首，
  /// 「录一句、写一句注解」的连续书写流）。
  void _insertMedia(String url, {required NoteMediaKind kind}) {
    final active = _activeText;
    final media = _MediaSeg(url, kind: kind);
    if (active == null) {
      _segs.add(media);
      _ensureTrailingText();
      _focusSeg(_segs.whereType<_TextSeg>().last);
    } else {
      final idx = _segs.indexOf(active);
      final sel = active.ctrl.selection;
      final offset = (sel.isValid ? sel.extentOffset : active.ctrl.text.length)
          .clamp(0, active.ctrl.text.length);
      final before = active.ctrl.text.substring(0, offset);
      final after = active.ctrl.text.substring(offset);
      active.ctrl.value = TextEditingValue(
        text: before,
        selection: TextSelection.collapsed(offset: before.length),
      );
      _segs.insert(idx + 1, media);
      final tail = _TextSeg(after);
      _segs.insert(idx + 2, tail);
      _focusSeg(tail);
    }
    _persistDraft();
    setState(() {});
  }

  /// 移除媒体段并**删除其私有副本文件**（未保存内容的拷贝，删了防孤儿文件；
  /// 已保存条目的文件归条目所有，不经此路径）。相邻文本段合并回一体。
  void _removeMedia(_MediaSeg m) {
    final i = _segs.indexOf(m);
    if (i < 0) return;
    _segs.removeAt(i);
    if (i > 0 && i < _segs.length) {
      final a = _segs[i - 1];
      final b = _segs[i];
      if (a is _TextSeg && b is _TextSeg) {
        a.ctrl.text += b.ctrl.text;
        b.dispose();
        _segs.removeAt(i);
      }
    }
    _ensureTrailingText();
    unawaited(() async {
      try {
        if (await m.file.exists()) await m.file.delete();
      } catch (e) {
        // 私有副本清理失败不影响数据正确性（保存后的条目不经此路径），
        // 但孤儿文件必须可观测
        debugPrint(
          '[DEGRADE] note_media_file_delete_failed url=${m.url} error=$e',
        );
      }
    }());
    _persistDraft();
    setState(() {});
  }

  void _focusSeg(_TextSeg seg, {int offset = -1}) {
    if (offset >= 0) {
      seg.ctrl.value = TextEditingValue(
        text: seg.ctrl.text,
        selection: TextSelection.collapsed(offset: offset),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      seg.focus.requestFocus();
      final ctx = seg.key.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 180),
          alignment: 0.15,
        );
      }
    });
  }

  /// 拖动/点按需要展开的总行程：从露出高度拉到接近整屏。
  /// 由可用高度动态算（拖动中随 MediaQuery 键盘变化保持一致手感）。
  double _travel(double available) =>
      (available - _peekHeight).clamp(120.0, double.infinity);

  void _expand() {
    if (mounted) {
      setState(() {
        _expanded = true;
        _dragSettling = true;
        _progress = 1; // 松手/点按：补间到满幅（TweenAnimationBuilder 接力动画）
      });
    }
    _expandedPersisted = true; // 变更点同步（Activity 重建不一定走 dispose）
    _activeText?.focus.requestFocus();
  }

  /// 收合：内容**不保存**（用户拍板「没点保存就留在便签里」），仅收起面板。
  void _collapse() {
    for (final s in _segs) {
      if (s is _TextSeg) s.focus.unfocus();
    }
    _persistDraft();
    _expandedPersisted = false;
    if (mounted) {
      setState(() {
        _expanded = false;
        _dragSettling = true;
        _progress = 0; // 补间回拉手态
      });
    }
  }

  /// 保存：全部段序列化为 human_md → **一个** note 条目 → 清空内容区
  /// （面板保持张开，可连续记）。
  ///
  /// 路由（用户拍板「媒体不分散保存 + 含媒体豁免合并」）：
  /// - 纯文本：走 `TextCollector.collectText`（合并窗口 / 纯 URL 拆分等既有逻辑不变）；
  /// - 含媒体：直发 `CollectCommand`（itemType=note、mode=scatter），永不并链。
  Future<void> _save() async {
    if (_sending) return;
    final models = <NoteSegment>[
      for (final s in _segs)
        switch (s) {
          _TextSeg(:final ctrl) => NoteTextSegment(ctrl.text),
          _MediaSeg(:final url, kind: NoteMediaKind.image) => NoteImageSegment(
            url,
          ),
          _MediaSeg(:final url, kind: NoteMediaKind.audio) => NoteAudioSegment(
            url,
          ),
          _MediaSeg(:final url, kind: NoteMediaKind.video) => NoteVideoSegment(
            url,
          ),
        },
    ];
    final body = serializeNoteMd(models, todoMode: _todoMode);
    if (body.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('先写点什么吧')));
      return;
    }
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tags = _pendingTags.isEmpty ? null : _pendingTags;
      if (noteHasMedia(models)) {
        await widget.handler.execute(
          CollectCommand(
            itemType: InboxItem.typeNote,
            sourceApp: '速记',
            rawContent: body,
            humanTitle: noteTitleOf(models) ?? '图文便签',
            tags: tags,
          ),
        );
      } else {
        await widget.collector.collectText(body, sourceApp: '速记', tags: tags);
      }
      if (!mounted) return;
      setState(() {
        for (final s in _segs) {
          if (s is _TextSeg) s.dispose();
        }
        _segs
          ..clear()
          ..add(_TextSeg());
        _draftSegsPersisted = const [];
        _pendingTags = [];
        _todoMode = false;
      });
      messenger.showSnackBar(const SnackBar(content: Text('已记下')));
    } catch (e) {
      // 失败原因原样告知（R1：错误要被用户感知，不自行编造兜底文案）
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('保存失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 拍照：复制进私有目录 → **插入光标处**（不再另立图片卡片）。
  Future<void> _photo() async {
    await _pickAndInsert(
      () => ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400),
      failMsg: '图片保存失败',
    );
  }

  /// 相册选图插入。
  Future<void> _pickAlbumImage() async {
    await _pickAndInsert(
      () =>
          ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2400),
      failMsg: '图片保存失败',
    );
  }

  Future<void> _pickAndInsert(
    Future<XFile?> Function() pick, {
    required String failMsg,
  }) async {
    if (_sending) return;
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await pick();
      if (file == null) return;
      final saved = await copyToAppDir(file.path);
      if (saved == null) {
        messenger.showSnackBar(SnackBar(content: Text(failMsg)));
        return;
      }
      _insertMedia(await toLocalMediaUrl(saved), kind: NoteMediaKind.image);
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('插图失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 录音：录 → 停止 → 播放条**插入光标处**（仅存音频，转写走详情页手动触发）。
  Future<void> _record() async {
    if (_sending) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_recording) {
      setState(() => _sending = true);
      try {
        final path = await _recorder.stop();
        setState(() => _recording = false);
        if (path == null) {
          messenger.showSnackBar(const SnackBar(content: Text('录音未保存')));
          return;
        }
        _insertMedia(await toLocalMediaUrl(path), kind: NoteMediaKind.audio);
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    if (!await _recorder.hasPermission()) {
      messenger.showSnackBar(const SnackBar(content: Text('缺少麦克风权限')));
      return;
    }
    setState(() => _sending = true);
    try {
      final dir = await appShareDir();
      final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      setState(() => _recording = true);
    } catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text('录音启动失败：$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 视频入口二选一面板（相册首位——主路径收集心智，note-video.md §1）。
  Future<void> _pickVideoSource() async {
    final source = await showModalBottomSheet<_VideoSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              subtitle: const Text('支持 MP4 / MOV，建议 5 分钟内'),
              onTap: () => Navigator.pop(ctx, _VideoSource.album),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍摄视频'),
              subtitle: const Text('最长 60 秒，自动停止'),
              onTap: () => Navigator.pop(ctx, _VideoSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    switch (source) {
      case _VideoSource.album:
        await _pickAlbumVideo();
      case _VideoSource.camera:
        await _captureVideo();
    }
  }

  /// 相册选视频（主路径，附件面板相册首位）：后置校验——
  /// mp4/mov 白名单、100MB 拦截、>5min 非阻断提示（note-video.md §2）。
  Future<void> _pickAlbumVideo() async {
    final check = await _pickVideoWithGate(
      () => ImagePicker().pickVideo(source: ImageSource.gallery),
      failMsg: '视频保存失败',
    );
    // check == null = 校验通过（note_video_policy 约定）：直接插入。
    // 非 null 且非阻断（>5min）走下方确认弹窗后再插。
    // 用户取消 / 拷贝失败 / 拦截类同样返回 null，但此时 _pendingVideoPath
    // 必为 null（gate 入口已清陈值），插入是空操作。
    if (check == null) {
      await _insertCheckedVideo();
      return;
    }
    if (check.blocking) return; // 拦截类已在 _pickVideoWithGate 提示
    if (!mounted) return;
    // 非阻断：>5min 提示后仍可添加
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('视频较长'),
        content: const Text('嵌入可能加载较慢，仍要添加吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('仍要添加'),
          ),
        ],
      ),
    );
    if (ok == true) await _insertCheckedVideo();
  }

  /// 相机直拍视频（次路径）：**自建拍摄页**（2026-10-01 拍板「自建拍摄页＋
  /// 进度环」——系统相机 Activity 上无法叠 App 进度 UI，60s 自动停不可感知）。
  /// 页面只产 ≤60s mp4 文件路径，白名单/大小/时长门槛照走统一校验链。
  Future<void> _captureVideo() async {
    final path = await NoteVideoCapturePage.push(
      context,
      maxDuration: noteVideoCaptureMaxDuration,
    );
    if (path == null || !mounted) return; // 取消/拍摄失败
    final check = await _pickVideoWithGate(
      () async => XFile(path),
      failMsg: '视频保存失败',
    );
    if (check == null) await _insertCheckedVideo();
  }

  /// 选/拍 → 落盘 → 后置校验；通过即插入。拦截类在此统一提示，
  /// 非阻断（>5min）返回 check 交调用方走确认弹窗。
  Future<NoteVideoCheck?> _pickVideoWithGate(
    Future<XFile?> Function() pick, {
    required String failMsg,
  }) async {
    if (_sending) return null;
    _pendingVideoPath = null; // 清陈值：取消/失败不得残留上一次的待插路径
    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await pick();
      if (file == null) return null;
      final saved = await copyToAppDir(file.path);
      if (saved == null) {
        messenger.showSnackBar(SnackBar(content: Text(failMsg)));
        return null;
      }
      final check = await checkNoteVideoAlbum(saved);
      if (check != null && check.blocking) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(switch (check.kind) {
              NoteVideoCheckKind.unsupportedFormat => '暂不支持该格式，建议使用 MP4 或 MOV',
              NoteVideoCheckKind.tooLarge => '视频过大（>100MB），建议剪短后再嵌入',
              NoteVideoCheckKind.unreadable => '视频无法读取',
              _ => '视频校验失败',
            }),
          ),
        );
        // 拦截类：已拷入私有目录的副本立即清理，防孤儿文件
        unawaited(() async {
          try {
            final f = File(saved);
            if (await f.exists()) await f.delete();
          } catch (e) {
            debugPrint(
              '[DEGRADE] note_video_reject_copy_delete_failed path=$saved error=$e',
            );
          }
        }());
        return null;
      }
      _pendingVideoPath = saved;
      return check;
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('视频添加失败：$e')));
      }
      return null;
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 把已通过校验的 [_pendingVideoPath] 插入为视频段。
  Future<void> _insertCheckedVideo() async {
    final saved = _pendingVideoPath;
    if (saved == null) return;
    _pendingVideoPath = null;
    _insertMedia(await toLocalMediaUrl(saved), kind: NoteMediaKind.video);
  }

  /// 标签：给本条未保存内容挂标签，随下次保存落库。
  Future<void> _pickTags() async {
    final ctl = TextEditingController(text: _pendingTags.join(' '));
    final tags = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('标签（空格分隔）'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：工作 灵感'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
              ctx,
              ctl.text
                  .trim()
                  .split(RegExp(r'\s+'))
                  .where((t) => t.isNotEmpty)
                  .toList(),
            ),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (tags != null && mounted) setState(() => _pendingTags = tags);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 连续形变（方案 A「跟手渐展」）：整个 build 只渲染**一张便签**——
    // 高度 = peek + progress × 行程，头部拉手与身体（顶栏/文本层/工具层）
    // 同属这一个容器，拖动时一起长出，不存在「头部先走、身体后到」。
    //
    // 展开态顶部锚定（2026-09-30 最终拍板「完全展开后顶到状态栏」）：面板顶缘
    // = 状态栏下沿，topInset 就是状态栏高度本身。状态栏高度必须取 FlutterView
    // 的原始 padding——本组件在 Scaffold body 内，body 的 MediaQuery.padding
    // 已被 Scaffold 消费（=0），用它避让等于不避让。
    final statusBar = MediaQueryData.fromView(View.of(context)).padding.top;
    final topInset = statusBar;
    // 面板最大高必须用 body 实际约束（LayoutBuilder），不放回 build 顶层算。

    // _expanded 只作稳定态判定：进度到位（≥0.999）才算展开，焦点/持久化挂它。
    final expandedNow = _expanded && _progress > 0.999;

    return Material(
      // 必须用 transparency 类型而非 transparent color：带颜色的 Material 即使
      // 全透明也会在整个边界内不透明地吸收命中测试，把下方列表的点击/滑动
      // 全部挡掉（2026-09-30 修「首页内容区不能点击和滑动」）。
      type: MaterialType.transparency,
      child: SafeArea(
        top: false,
        child: Padding(
          // 收合/展开与内容区同宽语言（用户拍板「便利贴和内容区同宽」）
          padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 面板最大高 = body 实际约束高 − topInset（顶缘锚在搜索框水平带）
              final available = (constraints.maxHeight - topInset).clamp(
                0.0,
                double.infinity,
              );
              return Align(
                alignment: Alignment.bottomCenter,
                child: GestureDetector(
                  onVerticalDragUpdate: expandedNow
                      ? null
                      : (d) {
                          // 拖动中零时长跟手：Δdy ÷ 总行程 → 进度增量，clamp 防拽出
                          setState(() {
                            _dragSettling = false;
                            _progress =
                                (_progress - d.delta.dy / _travel(available))
                                    .clamp(0.0, 1.0);
                          });
                        },
                  onVerticalDragEnd: expandedNow
                      ? null
                      : (d) {
                          final velocity = d.primaryVelocity ?? 0;
                          final fling = velocity < -120;
                          final lifted =
                              _progress > _peekHeight / _travel(available);
                          if (fling || lifted) {
                            _expand();
                          } else {
                            setState(() {
                              _dragSettling = true;
                              _progress = 0; // 未过阈值：补间回拉手
                            });
                          }
                        },
                  onVerticalDragCancel: () {
                    // 展开态必须忽略：点按面板内按钮（保存/标题/粗体等）时外层拖拽
                    // 识别器在竞技场落败会触发 cancel——若无此门控会把已展开面板
                    // 拽回收合（2026-09-30 修「点工具按钮面板坍缩」）。
                    if (expandedNow) return;
                    setState(() {
                      _dragSettling = true;
                      _progress = 0;
                    });
                  },
                  onTap: _expanded ? null : _expand,
                  // TweenAnimationBuilder 双态复用：拖动中 end 实时变、时长零 → 跟手；
                  // 松手/点按 end 定格、时长 260ms → 接力补间（回弹或展开完成）。
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: _progress),
                    duration: _dragSettling
                        ? const Duration(milliseconds: 260)
                        : Duration.zero,
                    curve: Curves.easeOutCubic,
                    builder: (context, t, child) =>
                        _morphSheet(scheme, t: t, available: available),
                  ),
                ),
              ); // Align
            }, // LayoutBuilder builder
          ),
        ),
      ),
    );
  }

  /// 形变中的便签：t∈[0,1]，0=拉手、1=满幅。
  /// 两个静止态（0 / 1）各走一棵**干净的树**（纯拉手 / 纯面板），保证命中
  /// 区域与布局和单态版本完全一致；只有形变中间态（拖动中 / 补间中）才做
  /// 高度增长 + 内容淡入上移，且中间态禁命中（IgnorePointer）防幽灵点按。
  Widget _morphSheet(
    ColorScheme scheme, {
    required double t,
    required double available,
  }) {
    final clamped = t.clamp(0.0, 1.0);

    // 静止收合：纯拉手（52px，无隐形内容——旧版幽灵控件/屏外溢出的根源）
    if (clamped <= 0) {
      return Container(
        height: _peekHeight,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.md),
          ),
          border: Border(
            top: BorderSide(color: scheme.outlineVariant, width: 1.5),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.22),
              blurRadius: 6,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: _buildPeek(scheme),
      );
    }

    // 静止展开：高度 = available（顶缘锚在状态栏下沿），不可省略 height。
    if (clamped >= 1) {
      return Container(
        height: available,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Radii.md),
          ),
          border: Border(
            top: BorderSide(
              color: scheme.primary.withValues(alpha: 0.55),
              width: 1.5,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: scheme.shadow.withValues(alpha: 0.22),
              blurRadius: 20,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: _buildExpanded(scheme),
      );
    }

    // 形变中间态：高度连续增长，头部拉手与身体一起长出
    final height = _peekHeight + (available - _peekHeight) * clamped;
    final contentOpacity =
        ((clamped - _contentFadeStart) / (1 - _contentFadeStart)).clamp(
          0.0,
          1.0,
        );
    // 拉手文字比面板淡出更早（0→0.2 消隐）：收合拉手与展开正文各有一份
    // 「记点什么…」，交叉淡化窗口若同步走，半途两个提示并存——文字先死
    // 后生（正文提示 0.35 才浮现），任何时刻全屏最多一份提示。
    final peekTextOpacity = (1 - clamped / 0.2).clamp(0.0, 1.0);
    final contentShift = (1 - clamped) * 24; // 内容轻微上移，增强「长出」感

    return Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Radii.md),
        ),
        border: Border(
          top: BorderSide(color: scheme.outlineVariant, width: 1.5),
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.22),
            blurRadius: 6,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: IgnorePointer(
        // 中间态禁命中：内容尚在淡入/位移，此刻的按钮位置不可信
        ignoring: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Opacity(
              opacity: (1 - contentOpacity).clamp(0.0, 1.0),
              child: _buildPeek(scheme, textOpacity: peekTextOpacity),
            ),
            Opacity(
              opacity: contentOpacity,
              child: Transform.translate(
                offset: Offset(0, contentShift),
                child: _buildExpanded(scheme),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 收合态：只露便签顶边拉手。
  Widget _buildPeek(ColorScheme scheme, {double textOpacity = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.md),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Opacity(
          opacity: textOpacity,
          child: Text(
            '记点什么…',
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  /// 展开态：三层平行结构——顶栏（钉在可见区顶部）/ 作曲层（满幅、内部
  /// 无限滚动、无底边）/ 工具层（独立覆盖底部，不随内容滚动消失）。
  Widget _buildExpanded(ColorScheme scheme) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(Insets.sm),
      child: Column(
        children: [
          // 顶栏
          Row(
            children: [
              IconButton(
                onPressed: _collapse,
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: '收起（内容保留在便签）',
              ),
              Expanded(
                child: Text(
                  _todayLabel,
                  textAlign: TextAlign.center,
                  style: textTheme.titleSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              // 内容感知 CTA（用户拍板）：空=实色禁用（无 M3 半透明罩，
              // 那层 onSurface@12% 罩叠面板即「脏」的来源），有内容=点亮
              // 橘红（橘红仅动作与选中）；白字+橘红是主题设计好的 onPrimary 对。
              ListenableBuilder(
                listenable: Listenable.merge([
                  for (final s in _segs)
                    if (s is _TextSeg) s.ctrl,
                ]),
                builder: (context, _) {
                  final ready = _hasContent && !_sending;
                  return FilledButton(
                    onPressed: ready ? _save : null,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      disabledBackgroundColor: scheme.surfaceContainer,
                      disabledForegroundColor: scheme.onSurfaceVariant
                          .withValues(alpha: 0.6),
                    ),
                    child: const Text('保存'),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          // 作曲层 + 工具层
          Expanded(
            child: Stack(
              children: [
                // 作曲层：满幅铺到面板底（工具层背后），内容超出内部滚动。
                // 视口底边止于工具层上沿：光标与末段永不滑进工具层底下。
                Positioned.fill(
                  child: AudioPlaybackService(
                    controller: _audioCtl,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: _toolLayerHeight),
                      child: ListView.builder(
                        padding: const EdgeInsets.only(top: Insets.xs),
                        itemCount: _segs.length,
                        itemBuilder: (context, i) => switch (_segs[i]) {
                          _TextSeg s => _textFieldFor(
                            s,
                            showHint: i == 0 && _segs.length == 1,
                          ),
                          _MediaSeg m => _mediaCard(m),
                        },
                      ),
                    ),
                  ),
                ),
                // 工具层：独立覆盖底部，内容怎么滚都不消失（键盘弹起贴键盘上沿）
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _toolLayer(scheme),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 文本段输入框（无边界，段间自然衔接；首段空态给提示语）。
  Widget _textFieldFor(_TextSeg seg, {required bool showHint}) {
    return TextField(
      key: seg.key,
      controller: seg.ctrl,
      focusNode: seg.focus,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textAlignVertical: TextAlignVertical.top,
      decoration: InputDecoration(
        hintText: showHint ? '记点什么…' : null,
        border: InputBorder.none,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(vertical: Insets.xs),
      ),
      style: Theme.of(context).textTheme.bodyLarge,
    );
  }

  /// 媒体段卡片：本体预览（与阅读态同源组件）+ 右上角移除按钮。
  Widget _mediaCard(_MediaSeg seg) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final exists = seg.file.existsSync();
    final body = switch (seg.kind) {
      NoteMediaKind.audio => MediaAudioBar(
        blockId: 'note-audio-${identityHashCode(seg)}',
        source: resolveLocalMediaSrc(seg.url),
        label: '录音',
        showSlider: true,
        degrade: classifyMediaUrl(seg.url) == MediaSuffix.audioDegrade,
      ),
      // 视频占位卡（封面提取留 V2，图标占位）：**点按可预览**——复用详情
      // 同一全屏播放器，草稿态即给用户「添加了什么、能不能播」的确认机会
      // （2026-10-01 真机反馈用户提议）；保存后详情 VideoBlock 同源同链路。
      NoteMediaKind.video => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: double.infinity,
          height: 220,
          child: Container(
            color: scheme.surfaceContainerHighest,
            child: exists
                ? InkWell(
                    onTap: () => showInlineVideoPlayer(
                      context,
                      url: seg.url,
                      label: '视频预览',
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.play_circle_outline,
                            size: 40,
                            color: scheme.primary,
                          ),
                          const SizedBox(height: Insets.xs),
                          Text(
                            '视频（点按预览，保存后详情可播放）',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  )
                : _missingCard(scheme, text: '视频文件丢失'),
          ),
        ),
      ),
      NoteMediaKind.image => ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: double.infinity,
          height: 220,
          child: Container(
            color: scheme.surfaceContainerHighest,
            child: exists
                ? GoodshareImage(
                    file: seg.file,
                    fit: BoxFit.cover,
                    cacheWidth: (dpr * 480).round(),
                    errorBuilder: (_, _, _) =>
                        _missingCard(scheme, text: '图片无法读取'),
                  )
                : _missingCard(scheme, text: '图片文件丢失'),
          ),
        ),
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xs),
      // body 作非定位子节点撑开 Stack（尺寸由本体决定），删除钮叠右上角
      child: Stack(
        children: [
          body,
          Positioned(
            top: 0,
            right: 0,
            child: IconButton.filledTonal(
              onPressed: () => _removeMedia(seg),
              icon: const Icon(Icons.close, size: 18),
              tooltip: '移除',
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _missingCard(ColorScheme scheme, {required String text}) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: Insets.xs),
          Text(text, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  /// 工具层（固定两行高：格式行 + 动作行）。
  Widget _toolLayer(ColorScheme scheme) {
    return SizedBox(
      height: _toolLayerHeight,
      child: Column(children: [_formatRow(), _actionRow(scheme)]),
    );
  }

  /// 格式行：标题 / 粗体。写作区是纯文本，格式 = 插入 Markdown 子集语法
  /// （详情页渲染器原生支持），不引富文本编辑器、不新增存储格式。
  Widget _formatRow() {
    return SizedBox(
      height: _toolLayerHeight / 2,
      child: Row(
        children: [
          IconButton(
            onPressed: _toggleHeading,
            icon: const Icon(Icons.title),
            tooltip: '标题',
          ),
          IconButton(
            onPressed: _wrapBold,
            icon: const Icon(Icons.format_bold),
            tooltip: '粗体',
          ),
        ],
      ),
    );
  }

  /// 动作行：拍照 / 相册 / 录音 / 视频 / 标签 / 待办 + 待挂标签内联提示。
  /// 拍照与相册是**就地插图**（语义反转：不再直接出独立卡片）；
  /// 视频入口收敛为二选一面板（相册首位——主路径收集心智，note-video.md §1）。
  Widget _actionRow(ColorScheme scheme) {
    return SizedBox(
      height: _toolLayerHeight / 2,
      child: Row(
        children: [
          IconButton(
            onPressed: _sending ? null : _photo,
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: '拍照插入便签',
          ),
          IconButton(
            onPressed: _sending ? null : _pickAlbumImage,
            icon: const Icon(Icons.photo_outlined),
            tooltip: '相册插图',
          ),
          IconButton(
            onPressed: _sending ? null : _record,
            icon: Icon(_recording ? Icons.stop : Icons.mic_none),
            tooltip: _recording ? '停止并插入录音' : '录音插入便签',
          ),
          IconButton(
            onPressed: _sending ? null : _pickVideoSource,
            icon: const Icon(Icons.movie_creation_outlined),
            tooltip: '视频插入便签',
          ),
          if (_recording)
            Text(
              '录音中…',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          const Spacer(),
          if (_pendingTags.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 88),
              child: Text(
                _pendingTags.map((t) => '#$t').join(' '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          IconButton(
            onPressed: _pickTags,
            icon: Badge(
              isLabelVisible: _pendingTags.isNotEmpty,
              label: Text('${_pendingTags.length}'),
              child: const Icon(Icons.tag),
            ),
            tooltip: '标签',
          ),
          IconButton(
            onPressed: () => setState(() => _todoMode = !_todoMode),
            icon: Icon(
              Icons.check_circle_outline,
              color: _todoMode ? scheme.primary : null,
            ),
            tooltip: _todoMode ? '待办模式（开）' : '待办模式',
          ),
        ],
      ),
    );
  }

  /// 标题：切换光标所在段的 `## ` 前缀（有则去、无则加），光标落段尾。
  void _toggleHeading() {
    final seg = _activeText;
    if (seg == null) return;
    final value = seg.ctrl.value;
    if (!value.selection.isValid) return;
    final text = value.text;
    final start = value.selection.start;
    final lineStart = start <= 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
    final nl = text.indexOf('\n', lineStart);
    final lineEnd = nl == -1 ? text.length : nl;
    final line = text.substring(lineStart, lineEnd);
    final stripped = line.replaceFirst(RegExp(r'^#{1,6}\s*'), '');
    final newLine = stripped.length == line.length ? '## $stripped' : stripped;
    seg.ctrl.value = TextEditingValue(
      text: text.replaceRange(lineStart, lineEnd, newLine),
      selection: TextSelection.collapsed(offset: lineStart + newLine.length),
    );
    seg.focus.requestFocus(); // 按钮点按会抢走焦点收键盘，拉回写作区
  }

  /// 粗体：选中文字包 `**`（保持选中）；无选中则插入 `****`、光标落中间。
  void _wrapBold() {
    final seg = _activeText;
    if (seg == null) return;
    final value = seg.ctrl.value;
    final sel = value.selection;
    if (!sel.isValid) return;
    final text = value.text;
    if (sel.start == sel.end) {
      seg.ctrl.value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.start, '****'),
        selection: TextSelection.collapsed(offset: sel.start + 2),
      );
    } else {
      final inner = text.substring(sel.start, sel.end);
      seg.ctrl.value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.end, '**$inner**'),
        selection: TextSelection(
          baseOffset: sel.start + 2,
          extentOffset: sel.end + 2,
        ),
      );
    }
    seg.focus.requestFocus(); // 按钮点按会抢走焦点收键盘，拉回写作区
  }
}
