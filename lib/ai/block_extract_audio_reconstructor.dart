import 'package:flutter/foundation.dart';

import '../data/block_artifacts.dart' show BlockArtifactInput, BlockArtifactKind;
import '../data/repository.dart';
import 'audio_extract.dart';
import 'reconstructor.dart';
import 'subtitle.dart' show SubtitleStore;

/// 行内视频块提取音轨（2026-10-05 v21，block-artifact-workflow.md §2.5）：
/// 认领 `block_extract_audio:<blockKey>` 任务，用 [AudioExtractor]（media-native
/// 原生链，流复制优先）把块视频的音轨导出成 audio_file 产物。
///
/// 产物 file_path 落 block_artifacts；条目级字段零触碰。失败（源缺失 / 无音轨 /
/// 编码不支持）→ blockArtifacts 空载荷 + note 明说原因（R1，可换格式重试）。
class BlockExtractAudioReconstructor implements AiReconstructor {
  const BlockExtractAudioReconstructor();

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> handles(ReconstructInput input) async {
    final block = Repository.parseBlockAction(input.taskAction);
    return block != null && block.$1 == 'block_extract_audio';
  }

  @override
  Future<ReconstructResult> reconstruct(ReconstructInput input) async {
    final blockKey = input.blockKey;
    final path = input.blockFilePath;
    if (blockKey == null || path == null || path.isEmpty) {
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        blockKey: blockKey,
        blockArtifacts: const [],
        note: '块视频文件缺失，无法提取音轨（媒体行可能已被移除）',
      );
    }
    // fileStem 必带块维度（2026-10-05 碰撞修复）：同一便签内多个视频块各自
    // 的音轨文件名 = blockFileStem(blockKey)，不再共享 itemId stem 互相覆盖
    //（覆盖 + 删行删盘会误删其他块正在引用的物理文件）。
    final r = await AudioExtractor.extract(
      path,
      itemId: input.itemId,
      fileStem: SubtitleStore.blockFileStem(blockKey),
    );
    if (!r.ok) {
      return ReconstructResult(
        humanMd: input.rawContent ?? '',
        blockKey: blockKey,
        blockArtifacts: const [],
        note: r.error ?? '音轨提取失败',
      );
    }
    debugPrint('[BlockExtractAudio] -> ${r.path} (item=${input.itemId})');
    return ReconstructResult(
      humanMd: input.rawContent ?? '',
      blockKey: blockKey,
      blockArtifacts: [BlockArtifactInput(BlockArtifactKind.audioFile, filePath: r.path)],
    );
  }
}
