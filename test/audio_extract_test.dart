import 'package:flutter_test/flutter_test.dart';
import 'package:goodshare/ai/audio_extract.dart';
import 'package:goodshare/data/repository.dart';
import 'package:goodshare/models/item.dart';
import 'package:goodshare/pages/item_detail_page.dart';

/// 音轨提取的格式契约单测（2026-09-28 建；media-native P4 起导出走原生）。
///
/// 只测**纯函数**部分（容器选择）——原生导出调用需真机，本机无设备；
/// 而最容易出错、也最需要守护的正是「源编码 → 目标容器」这张映射表：
/// 映射错了，流复制会失败或产出打不开的文件。
void main() {
  group('extensionForCodec（流复制的容器选择）', () {
    test('常见编码各自落到对的容器', () {
      expect(extensionForCodec('aac'), 'm4a');
      expect(extensionForCodec('alac'), 'm4a');
      expect(extensionForCodec('mp3'), 'mp3');
      expect(extensionForCodec('opus'), 'ogg');
      expect(extensionForCodec('vorbis'), 'ogg');
      expect(extensionForCodec('flac'), 'flac');
      expect(extensionForCodec('pcm_s16le'), 'wav');
    });

    test('未知 / 缺失回落 m4a（aac 系统编码器可兜底）', () {
      expect(extensionForCodec(null), 'm4a');
      expect(extensionForCodec(''), 'm4a');
      expect(extensionForCodec('wmav2'), 'm4a');
    });

    test('大小写不敏感（探测输出不保证大小写）', () {
      expect(extensionForCodec('AAC'), 'm4a');
      expect(extensionForCodec('MP3'), 'mp3');
    });
  });

  group('AudioExportFormat（枚举 name 即通道 format 参数）', () {
    test('copy/m4a/flac/wav 与原生协议字符串同名', () {
      expect(AudioExportFormat.copy.name, 'copy');
      expect(AudioExportFormat.m4a.name, 'm4a');
      expect(AudioExportFormat.flac.name, 'flac');
      expect(AudioExportFormat.wav.name, 'wav');
    });
  });

  /// 用户实测痛点（2026-09-28）：中文模型转写英文音频 → 空产出被记成成功
  /// （is_processed=1），详情页一片空白，用户分不清失败还是成功。
  group('AI 任务反馈文案', () {
    InboxItem item({String body = '', String? translated}) => InboxItem(
          itemType: InboxItem.typeAudio,
          rawContent: body,
          humanMd: body.isEmpty ? null : body,
          translatedMd: translated,
          translateLang: translated == null ? null : 'zh',
          createdAt: 1,
        );

    test('进行中 / 失败 / 暂停 / 取消各有明确说法', () {
      expect(aiTaskStatusText('pending', Repository.taskTranscribeAudio, true), contains('处理中'));
      expect(aiTaskStatusText('processing', Repository.taskTranscribeAudio, true), contains('处理中'));
      expect(aiTaskStatusText('failed', Repository.taskTranscribeAudio, true), contains('失败'));
      expect(aiTaskStatusText('paused', Repository.taskTranscribeAudio, true), contains('暂停'));
      expect(aiTaskStatusText('cancelled', Repository.taskTranscribeAudio, true), contains('取消'));
    });

    test('已产出则不提示（避免噪音）', () {
      expect(aiTaskStatusText('completed', Repository.taskTranscribeAudio, false), isEmpty);
    });

    test('转写完成但空产出 → 给出换多语种模型的指引（中文模型跑英文）', () {
      final t = aiTaskStatusText('completed', Repository.taskTranscribeAudio, true);
      expect(t, contains('没有识别出任何文本'));
      expect(t, contains('多语种')); // 可执行下一步，而非只说「失败」
    });

    test('OCR 空产出 → 指向图片本身', () {
      expect(aiTaskStatusText('completed', Repository.taskOcrAndExtract, true), contains('图片'));
    });

    test('空产出判定：翻译看译文，其余看正文', () {
      expect(aiTaskEmptyOutput(Repository.taskTranslate, item(translated: null)), isTrue);
      expect(aiTaskEmptyOutput(Repository.taskTranslate, item(translated: '译文')), isFalse);
      expect(aiTaskEmptyOutput(Repository.taskTranscribeAudio, item(body: '')), isTrue);
      expect(aiTaskEmptyOutput(Repository.taskTranscribeAudio, item(body: '有字')), isFalse);
    });

    test('管线给的 note 优先于兜底文案（错误具体到可行动）', () {
      final t = aiTaskStatusText(
        'failed',
        Repository.taskTranscribeAudio,
        true,
        note: '模型「全能 · 多语种」未下载，请下载后再试',
      );
      expect(t, contains('未下载')); // 真实原因，不是泛泛的「失败」
      expect(t, contains('重启该任务')); // 下一步指引仍在
    });

    test('完成但空产出带 note → 直接显示原因，不猜兜底文案', () {
      final t = aiTaskStatusText(
        'completed',
        Repository.taskTranscribeAudio,
        true,
        note: '音频没有语音内容',
      );
      expect(t, contains('音频没有语音内容'));
    });
  });
}
