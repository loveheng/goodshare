import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

/// 在线渲染端点（mermaid.ink）：`GET /img/pako:<zlib+base64>` 返回 PNG。
///
/// 后续若要换自建 kroki（隐私口径收紧时），只改这里 + [_fetch] 的载荷编码。
const String kMermaidRenderEndpoint = 'https://mermaid.ink/img';

/// mermaid 在线渲染的超时（首图是网络往返，冷启动可达数秒）。
const Duration _kConnectTimeout = Duration(seconds: 10);
const Duration _kReceiveTimeout = Duration(seconds: 15);

final Dio _dio = Dio(
  BaseOptions(
    connectTimeout: _kConnectTimeout,
    receiveTimeout: _kReceiveTimeout,
    followRedirects: true,
    responseType: ResponseType.bytes,
  ),
);

/// 转码产物：位图字节 + 宽高比（PNG 头解析）。
class _Raster {
  const _Raster(this.bytes, this.aspect);

  final Uint8List bytes;
  final double aspect;
}

/// mermaid 图表渲染（2026-10-09 拍板改「在线渲染服务」）。
///
/// **当前未接入（2026-10-09 用户拍板还原）**：在线渲染加载过慢，正文里的
/// mermaid 块改回普通代码块显示（见 `rich_text_view.dart` CodeBlock 分支）。
/// 本件**保留待复用**——在线方案已实现完整（dio 直连 + 缓存 + 失败分档），
/// 要重新启用只需把 CodeBlock 分支改回按 `language == 'mermaid'` 分流。
/// 若长期无宿主，与 rotary_dial/format_dial 同口径评估清偿（见 context/todos.md）。
///
/// 以下为原设计说明：
///
/// **为什么不再本地转码**（本地 js + 屏外 WebView 方案已下线）：
/// ① 本地转码产物是 SVG，flutter_svg 吃不下——`<marker>` 箭头不支持、配色
///    写在内嵌 `<style>` CSS 类里支持很弱、**节点框按浏览器字体度量算而文字
///    按 Flutter 字体度量画**（必然溢出错位）；② 改在 WebView 里栅格化虽能
///    保真，却多背 3.5MB 本地 js 与 WebView 合成开销。在线服务直接给 PNG：
///    包体 -3.5MB，版式由服务端 mermaid 官方渲染，1:1 保真。
///
/// **隐私红线（待办，见 context/todos.md）**：本实现会把 **mermaid 块源码**
/// 明文发给第三方 `mermaid.ink`；当前口径是「不区分条目，全部可发」（用户
/// 2026-10-09 拍板：先试效果）。上线前必须补：保险箱/上锁条目禁发 + 设置项
/// 开关 + 可换自建端点。
///
/// 两态语义（用户拍板「编辑错原样显示」）：语法错误（服务端 400）/ 网络失败 /
/// 超时 → **原地退代码块形态**（宿主经 [fallbackBuilder] 传入，源码不丢）。
class MermaidView extends StatefulWidget {
  const MermaidView({
    super.key,
    required this.code,
    required this.fallbackBuilder,
  });

  /// mermaid 源码（CodeBlock.code，围栏内文本）。
  final String code;

  /// 降级态构建（现行代码块渲染：语言徽标 + 复制）。
  final WidgetBuilder fallbackBuilder;

  @override
  State<MermaidView> createState() => _MermaidViewState();
}

class _MermaidViewState extends State<MermaidView> {
  _Raster? _raster;
  bool _failed = false;
  bool _loading = false;

  /// 结果缓存（详情页正文走 SliverList 虚拟化，块滚出屏即销毁、滚回来重建；
  /// 无缓存就是每次滚回来重打一次网络）。位图按**字节**设上限。
  static final Map<String, _Raster> _pngCache = <String, _Raster>{};
  /// 明确「画不出」的源码（服务端 400：语法错）——重试无意义，直接退代码块。
  /// 网络类失败**不进**这里：恢复网络后要能自动重试。
  static final Set<String> _badCache = <String>{};
  static const int _cacheMaxBytes = 6 * 1024 * 1024;
  static int _cacheBytes = 0;

  /// 缓存键含明暗：服务按主题出图，切换后必须重取。
  String get _cacheKey =>
      '${Theme.of(context).brightness.name}\u0000${widget.code}';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant MermaidView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 源码变了（AI 写回 / 就地编辑保存后重渲染）：清态重取，不复用旧图。
    if (oldWidget.code == widget.code) return;
    _raster = null;
    _failed = false;
    _resolve();
  }

  Future<void> _resolve() async {
    final key = _cacheKey;
    final cached = _pngCache[key];
    if (cached != null) {
      if (mounted) setState(() => _raster = cached);
      return;
    }
    if (_badCache.contains(key)) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (_loading) return;
    _loading = true;
    try {
      final bytes = await _fetch();
      final size = _pngSize(bytes);
      if (size == null) {
        _fail('产物不是合法 PNG（${bytes.length}B）');
        return;
      }
      final raster = _Raster(bytes, size.$1 / size.$2);
      _putCache(key, raster);
      if (!mounted) return;
      setState(() => _raster = raster);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400) {
        // 语法错：写失败缓存，别每次进页面都空跑一次网络
        _failBad('服务端拒绝（400 语法错误）');
      } else {
        _fail('在线渲染失败：$status ${e.message}');
      }
    } catch (e) {
      _fail('在线渲染异常：$e');
    } finally {
      _loading = false;
    }
  }

  /// 打在线服务拿 PNG（pako 载荷 = zlib 压缩的 `{code, mermaid 配置}`）。
  Future<Uint8List> _fetch() async {
    final mq = MediaQuery.of(context);
    final cssWidth = (mq.size.width - 2 * Insets.xl).clamp(120.0, 720.0);
    // 按**屏幕物理像素**出图：清晰度够，又不至于拉回超大位图
    final px = (cssWidth * mq.devicePixelRatio.clamp(1.0, 3.0)).round();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final payload = jsonEncode({
      'code': widget.code,
      'mermaid': {
        'securityLevel': 'strict',
        // 服务端渲染走 puppeteer：关 foreignObject 让标签走原生 <text>
        'htmlLabels': false,
      },
    });
    final pako =
        base64Encode(ZLibCodec(level: 9).encode(utf8.encode(payload)));
    final query = '?theme=${dark ? 'dark' : 'default'}&bg=transparent&width=$px';
    try {
      return await _get(
          '$kMermaidRenderEndpoint/pako:${Uri.encodeComponent(pako)}$query');
    } on DioException catch (e) {
      // pako 载荷被拒 → 退回「明文 base64 源码」载荷重试一次。端点两种编码都
      // 支持，兜底是为了首次上线不因编码差异整片降级（语法错同样返回 400，
      // 此时两种载荷都失败 → 最终按 400 退代码块）。
      if (e.response?.statusCode != 400) rethrow;
      final plain = base64Encode(utf8.encode(widget.code));
      return await _get(
          '$kMermaidRenderEndpoint/${Uri.encodeComponent(plain)}$query');
    }
  }

  Future<Uint8List> _get(String url) async {
    final res = await _dio.get<List<int>>(url);
    final data = res.data;
    if (data == null || data.isEmpty) {
      throw Exception('空响应');
    }
    return Uint8List.fromList(data);
  }

  /// 记入成功缓存（按字节上限淘汰最早的一批）。
  void _putCache(String key, _Raster raster) {
    _badCache.remove(key);
    final old = _pngCache.remove(key);
    if (old != null) _cacheBytes -= old.bytes.lengthInBytes;
    final need = raster.bytes.lengthInBytes;
    if (_cacheBytes + need > _cacheMaxBytes) {
      for (final k in _pngCache.keys.toList()) {
        if (_cacheBytes + need <= _cacheMaxBytes) break;
        final v = _pngCache.remove(k);
        if (v != null) _cacheBytes -= v.bytes.lengthInBytes;
      }
    }
    _pngCache[key] = raster;
    _cacheBytes += need;
  }

  /// 唯一出口：转圈 → 代码块（画不出就是码，绝不留在转圈态）。
  void _fail(String reason) {
    if (!mounted || _failed) return;
    // DEGRADE: 在线渲染降级需真机可取证，日志前缀统一 [mermaid]
    debugPrint('[DEGRADE] [mermaid] 退代码块：$reason');
    setState(() => _failed = true);
  }

  void _failBad(String reason) {
    _badCache.add(_cacheKey);
    _fail(reason);
  }

  /// PNG 头解析宽高（IHDR：8 字节签名 + 4 长度 + 4 类型 后紧跟 w/h）。
  static (double, double)? _pngSize(Uint8List b) {
    if (b.length < 24) return null;
    final bd = ByteData.sublistView(b);
    final w = bd.getUint32(16);
    final h = bd.getUint32(20);
    if (w <= 0 || h <= 0) return null;
    return (w.toDouble(), h.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raster = _raster;
    if (_failed || raster == null) {
      // 降级态：源码原样显示（代码块形态，宿主传入）
      if (_failed) return widget.fallbackBuilder(context);
      // 转码中占位（三态硬规则：loading 骨架，不抛红屏）
      return Container(
        height: 96,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // 图表态：在线服务出的 PNG（按屏幕物理像素），纯原生渲染、零手势通道
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: SizedBox(
        width: double.infinity,
        child: AspectRatio(
          aspectRatio: raster.aspect,
          child: Image.memory(
            raster.bytes,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
  }
}
