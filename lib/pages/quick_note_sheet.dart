import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../ai/capabilities.dart';
import '../data/repository.dart';
import '../models/item.dart';
import '../share/attachments.dart';
import '../share/text_collector.dart';

/// 速记 / 分类添加面板（设计 §4.6 + §4.7 分类添加）。
/// initialType = null：速记默认（文本 + 录音 + 拍照）；
/// 指定类型：该类型的专用添加入口（便签→文本、链接→地址、图片/聊天→截图、
/// 视频/音频/文档→选取文件），全部走与分享相同的摄入路径（入库即入队）。
class QuickNoteSheet extends StatefulWidget {
  const QuickNoteSheet({
    super.key,
    required this.repo,
    required this.collector,
    required this.caps,
    this.initialType,
  });

  final Repository repo;
  final TextCollector collector;
  final AiCapabilities caps;
  final String? initialType;

  @override
  State<QuickNoteSheet> createState() => _QuickNoteSheetState();
}

class _QuickNoteSheetState extends State<QuickNoteSheet> {
  final _textCtrl = TextEditingController();
  final _recorder = AudioRecorder();
  final _stt = SpeechToText();
  bool _recording = false;
  bool _busy = false;
  bool _sttUnavailable = false;
  String _transcript = '';

  String? get _mode => widget.initialType;
  String get _sourceApp => _mode == null ? '速记' : '手动添加';

  @override
  void dispose() {
    _textCtrl.dispose();
    _recorder.dispose();
    _stt.stop();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _closeSnack(String message) async {
    if (mounted) Navigator.pop(context);
    _snack(message);
  }

  String _titleFor(String prefix) {
    final now = DateTime.now();
    return '$prefix ${now.hour}:${now.minute.toString().padLeft(2, '0')}';
  }

  /// 媒体类添加：复制进私有目录 → 建条目 → 按类型入队。
  Future<void> _saveAttachment(String itemType, String path) async {
    final saved = await copyToAppDir(path);
    if (saved == null) {
      _snack('文件保存失败');
      return;
    }
    final isAudio = itemType == InboxItem.typeAudio;
    final item = await widget.repo.add(InboxItem(
      itemType: itemType,
      sourceType: itemType,
      sourceApp: _sourceApp,
      humanTitle: isAudio
          ? _titleFor('录音')
          : (saved.split('/').last),
      rawContent: isAudio && _transcript.isNotEmpty ? _transcript : null,
      rawFilePath: saved,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    ));
    await widget.repo.enqueueTask(item.id!, Repository.taskActionFor(itemType));
  }

  Future<void> _saveText() async {
    if (_busy) return;
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      _snack('先写点什么吧');
      return;
    }
    final saved = await widget.collector.collectText(text, sourceApp: _sourceApp);
    if (saved == null) {
      _snack('保存失败');
      return;
    }
    await _closeSnack(_mode == InboxItem.typeUrl ? '链接已收集，后台抓取正文中' : '已收集');
  }

  Future<void> _pickImage({required bool fromCamera, bool asChatlog = false}) async {
    if (_busy) return;
    _busy = true;
    try {
      final photo = await ImagePicker().pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 2400,
      );
      if (photo == null) return;
      // 聊天记录来自截图：入库 provisional 为 image，AI 管线重分类为 chatlog
      final saved = await copyToAppDir(photo.path);
      if (saved == null) {
        _snack('图片保存失败');
        return;
      }
      final item = await widget.repo.add(InboxItem(
        itemType: InboxItem.typeImage,
        sourceType: InboxItem.typeImage,
        sourceApp: _sourceApp,
        humanTitle: _titleFor(asChatlog ? '聊天截图' : '拍照'),
        rawFilePath: saved,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await widget.repo.enqueueTask(item.id!, Repository.taskActionFor(InboxItem.typeImage));
      await _closeSnack(asChatlog ? '截图已收集，待 AI 识别为聊天' : '图片已收集');
    } finally {
      _busy = false;
    }
  }

  Future<void> _pickVideo() async {
    if (_busy) return;
    _busy = true;
    try {
      final video = await ImagePicker().pickVideo(source: ImageSource.gallery);
      if (video == null) return;
      await _saveAttachment(InboxItem.typeVideo, video.path);
      await _closeSnack('视频已收集');
    } finally {
      _busy = false;
    }
  }

  Future<void> _pickDocument() async {
    if (_busy) return;
    _busy = true;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'csv', 'epub'],
      );
      if (files.isEmpty) return;
      final path = files.single.path;
      if (path == null) return;
      await _saveAttachment(InboxItem.typeDocument, path);
      await _closeSnack('文档已收集');
    } finally {
      _busy = false;
    }
  }

  Future<void> _pickAudioFile() async {
    if (_busy) return;
    _busy = true;
    try {
      final files = await FilePicker.pickFiles(type: FileType.audio);
      if (files.isEmpty) return;
      final path = files.single.path;
      if (path == null) return;
      final item = await widget.repo.add(InboxItem(
        itemType: InboxItem.typeAudio,
        sourceType: InboxItem.typeAudio,
        sourceApp: _sourceApp,
        humanTitle: path.split('/').last,
        rawFilePath: (await copyToAppDir(path)) ?? path,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await widget.repo.enqueueTask(item.id!, Repository.taskActionFor(InboxItem.typeAudio));
      await _closeSnack('音频已收集');
    } finally {
      _busy = false;
    }
  }

  Future<void> _toggleRecord() async {
    if (_busy) return;
    if (_recording) {
      _busy = true;
      try {
        final path = await _recorder.stop();
        await _stt.stop();
        setState(() => _recording = false);
        if (path == null) {
          _snack('录音未保存');
          return;
        }
        final now = DateTime.now();
        final item = await widget.repo.add(InboxItem(
          itemType: InboxItem.typeAudio,
          sourceType: InboxItem.typeAudio,
          sourceApp: _sourceApp,
          humanTitle: _titleFor('录音'),
          rawContent: _transcript.isEmpty ? null : _transcript,
          rawFilePath: path,
          createdAt: now.millisecondsSinceEpoch,
        ));
        // 转写文本在采集时已入 raw 层，消费者占位复制到 human_md
        await widget.repo.enqueueTask(item.id!, Repository.taskActionFor(InboxItem.typeAudio));
        await _closeSnack(
            _transcript.isEmpty ? '录音已收集（未产生转写文本）' : '录音已收集（含转写文本）');
      } finally {
        _busy = false;
      }
      return;
    }
    if (!await _recorder.hasPermission()) {
      _snack('缺少麦克风权限');
      return;
    }
    _busy = true;
    try {
      final dir = await appShareDir();
      final path = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      setState(() {
        _recording = true;
        _transcript = '';
      });
      // 端侧转写：受设置开关与本机检测门控（D7：仅请求 onDevice，不支持则明示仅存音频）。
      // Android 系统语音识别只支持实时流，故转写与录音同步进行。
      final sttAllowed =
          widget.caps.sttEnabled && widget.caps.sttAvailable != false;
      if (!sttAllowed) {
        setState(() => _sttUnavailable = true);
        _snack(widget.caps.sttEnabled
            ? '本机不支持端侧语音转写，仅保存音频'
            : '转写已在设置中关闭，仅保存音频');
      } else {
        try {
          final ready = await _stt.initialize();
          if (!ready) throw StateError('unavailable');
          await _stt.listen(
            onResult: (r) {
              if (r.recognizedWords.isNotEmpty) {
                setState(() => _transcript = r.recognizedWords);
              }
            },
            listenOptions: SpeechListenOptions(
              onDevice: true,
              cancelOnError: true,
              partialResults: true,
              listenMode: ListenMode.dictation,
            ),
          );
          setState(() => _sttUnavailable = false);
        } catch (e) {
          debugPrint('[QuickNote] STT on-device unavailable: $e');
          setState(() => _sttUnavailable = true);
          _snack('本机不支持端侧语音转写，仅保存音频');
        }
      }
    } catch (e) {
      _snack('录音启动失败：$e');
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_mode != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('添加${_modeLabel(_mode!)}',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ..._buildBody(),
        ],
      ),
    );
  }

  String _modeLabel(String type) => switch (type) {
        InboxItem.typeNote => '便签',
        InboxItem.typeUrl => '链接',
        InboxItem.typeImage => '图片',
        InboxItem.typeVideo => '视频',
        InboxItem.typeAudio => '音频',
        InboxItem.typeChatlog => '聊天（截图）',
        InboxItem.typeDocument => '文档',
        _ => type,
      };

  List<Widget> _buildBody() {
    switch (_mode) {
      case InboxItem.typeUrl:
        return [
          TextField(
            controller: _textCtrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: '粘贴链接地址，保存后自动离线抓取网页正文',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _saveText, child: const Text('保存')),
        ];
      case InboxItem.typeImage:
        return _mediaButtons([
          ('拍照收集', Icons.photo_camera_outlined, () => _pickImage(fromCamera: true)),
          ('相册选图', Icons.photo_outlined, () => _pickImage(fromCamera: false)),
        ]);
      case InboxItem.typeChatlog:
        return _mediaButtons([
          (
            '选择聊天截图',
            Icons.screenshot_outlined,
            () => _pickImage(fromCamera: false, asChatlog: true),
          ),
        ]);
      case InboxItem.typeVideo:
        return _mediaButtons([
          ('选择视频', Icons.videocam_outlined, _pickVideo),
        ]);
      case InboxItem.typeAudio:
        return [
          Row(
            children: [
              IconButton.filledTonal(
                tooltip: _recording ? '停止并保存' : '录音',
                onPressed: _toggleRecord,
                icon: Icon(_recording ? Icons.stop : Icons.mic_none),
              ),
              if (_recording)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text('录音中…', style: TextStyle(color: Colors.redAccent)),
                ),
              const Spacer(),
              OutlinedButton(
                onPressed: _pickAudioFile,
                child: const Text('选音频文件'),
              ),
            ],
          ),
          if (_recording) ...[
            if (_transcript.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _transcript,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_sttUnavailable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('本机不支持端侧语音转写，仅保存音频',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ];
      case InboxItem.typeDocument:
        return _mediaButtons([
          ('选择文档', Icons.description_outlined, _pickDocument),
        ]);
      case InboxItem.typeNote:
        return _noteBody();
      default:
        return _noteBody();
    }
  }

  List<Widget> _noteBody() {
    return [
      TextField(
        controller: _textCtrl,
        maxLines: 4,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '速记一段话…（合并模式下同源连续速记会追加为一条）',
        ),
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          IconButton.filledTonal(
            tooltip: _recording ? '停止并保存' : '录音',
            onPressed: _toggleRecord,
            icon: Icon(_recording ? Icons.stop : Icons.mic_none),
          ),
          if (_recording)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Text('录音中…', style: TextStyle(color: Colors.redAccent)),
            ),
          const Spacer(),
          IconButton.filledTonal(
            tooltip: '拍照收集',
            onPressed: () => _pickImage(fromCamera: true),
            icon: const Icon(Icons.photo_camera_outlined),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _saveText,
            child: const Text('保存'),
          ),
        ],
      ),
    ];
  }

  List<Widget> _mediaButtons(List<(String, IconData, VoidCallback)> actions) {
    return [
      for (final (label, icon, onTap) in actions)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            onPressed: onTap,
            icon: Icon(icon),
            label: Text(label),
          ),
        ),
    ];
  }
}
