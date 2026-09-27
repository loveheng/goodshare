import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../data/repository.dart';
import '../models/item.dart';
import '../share/attachments.dart';
import '../share/text_collector.dart';

/// FAB 速记（设计 §4.6）：新建文本 / 录音 / 拍照，MVP 语义为「先存下来」——
/// 录音存 audio 原始条目、拍照存 image 条目并入 ocr 队列；「转待办 / OCR 增强」
/// 随 V2 端侧能力解锁（F3 决策）。文本走 TextCollector（与分享同路径、同合并模式）。
class QuickNoteSheet extends StatefulWidget {
  const QuickNoteSheet({super.key, required this.repo, required this.collector});

  final Repository repo;
  final TextCollector collector;

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

  Future<void> _saveText() async {
    if (_busy) return;
    final saved = await widget.collector.collectText(_textCtrl.text, sourceApp: '速记');
    if (saved == null) {
      _snack('先写点什么吧');
      return;
    }
    await _closeSnack('已收集');
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
          sourceApp: '速记',
          humanTitle: '速记录音 ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
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
      // 端侧转写（D7：仅请求 onDevice；不支持则明示回退，仅保存音频）。
      // Android 系统语音识别只支持实时流，故转写与录音同步进行。
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
    } catch (e) {
      _snack('录音启动失败：$e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _pickPhoto() async {
    if (_busy) return;
    _busy = true;
    try {
      final photo = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400);
      if (photo == null) return;
      final saved = await copyToAppDir(photo.path);
      if (saved == null) {
        _snack('照片保存失败');
        return;
      }
      final now = DateTime.now();
      final item = await widget.repo.add(InboxItem(
        itemType: InboxItem.typeImage,
        sourceType: InboxItem.typeImage,
        sourceApp: '速记',
        humanTitle: '速记拍照 ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
        rawFilePath: saved,
        createdAt: now.millisecondsSinceEpoch,
      ));
      // 入 ocr 队列（MVP 占位；V2 端侧 OCR 产出文本）
      await widget.repo.enqueueTask(item.id!, Repository.taskOcrAndExtract);
      await _closeSnack('照片已收集');
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
          TextField(
            controller: _textCtrl,
            maxLines: 4,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '速记一段话…（合并模式下同源连续速记会追加为一条）',
            ),
          ),
          const SizedBox(height: 12),
          if (_recording) ...[
            if (_transcript.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _transcript,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (_sttUnavailable)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('本机不支持端侧语音转写，仅保存音频',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
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
                onPressed: _pickPhoto,
                icon: const Icon(Icons.photo_camera_outlined),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saveText,
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
