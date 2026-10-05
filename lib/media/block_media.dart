/// 块媒体行的类型信息与物理路径解析（block-artifact-workflow.md §2.5 输入源分叉）。
///
/// 落在 lib/media/ 管依赖方向：action/ai → media → doc（path_provider 直取，
/// 不 import share，避免与 share → action 的既有依赖成环）。
/// 动作层校验只用 [BlockMedia]（类型/后缀）；物理路径由重建器经
/// [resolveBlockMediaPath] 异步解析（首个调用后 path_provider 自缓存，开销可忽略）。
library;

import 'package:path_provider/path_provider.dart';

import '../doc/rich_text.dart' show MediaSuffix;

/// 块媒体行解析结果：类型 + 后缀归类。
class BlockMedia {
  const BlockMedia({required this.url, required this.isImage, required this.suffix});

  /// 媒体行 url（= block_key，逐字相等）。
  final String url;

  /// 是否图片块（ImageBlock）。
  final bool isImage;

  /// 音视后缀归类（图片块恒 [MediaSuffix.unknown]）。
  final MediaSuffix suffix;
}

/// 块媒体 url（`local://…`）→ documents 沙箱内绝对路径。
///
/// 非本地 url / 目录未就绪时原样返回（调用方按文件不存在处理，与渲染层
/// resolveLocalMediaSrc 同降级口径——产物任务会以 note 明说，不静默）。
Future<String> resolveBlockMediaPath(String url) async {
  if (!url.startsWith('local://')) return url;
  final dir = await getApplicationDocumentsDirectory();
  return '${dir.path}/${url.substring('local://'.length)}';
}
