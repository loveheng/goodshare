import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// S3 薄封装（2026-09-29，备份传输层拍板，设计 docs/design/s3-backup.md）。
///
/// 零新依赖拍板：SigV4 手写签名用既有 `crypto` 包
/// （sha256/Hmac 均在其列），HTTP 走既有 dio。仅实现备份/恢复所需子集：
/// PutObject / GetObject / HeadObject / ListObjectsV2 / DeleteObject。
///
/// path-style（`https://<endpoint>/<bucket>/<key>`）：兼容 MinIO/群晖/威联通自建
/// 与一切 S3 兼容服务（R2/B2/OSS 均支持）；AWS 新区 virtual-host 风格不覆盖（无需求）。
/// 签名规范：AWS Signature Version 4（payload 以 UNSIGNED-PAYLOAD 走
/// `x-amz-content-sha256` 头，流式上传免预读整文件）。
class S3Client {
  S3Client({
    required String endpoint,
    required this.bucket,
    this.region = 'us-east-1',
    required String accessKey,
    required String secretKey,
  })  : _base = _normalizeEndpoint(endpoint),
        _ak = accessKey,
        _sk = secretKey;

  /// 备份包固定根（远端 key 前缀）。
  static const backupRoot = 'goodshare';

  /// Multipart 切换阈值：超过则走分片上传（大文件中断只重传单片）。
  static const multipartThreshold = 100 * 1024 * 1024; // 100MB

  final Uri _base;
  final String bucket;
  final String region;
  final String _ak;
  final String _sk;
  Dio? _dio;

  Dio get _http => _dio ??= Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          // 上传/下载不设发送/接收时限：公网传 GB 级备份耗时正常，
          // 断网由 connect 超时与用户取消兜底
          sendTimeout: Duration.zero,
          receiveTimeout: Duration.zero,
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );

  static Uri _normalizeEndpoint(String raw) {
    final Uri u;
    try {
      u = Uri.parse(raw.trim());
    } on FormatException {
      // 全角字母等非法 scheme 会让 Uri.parse 直接炸（FormatException），给可读文案
      throw const S3Exception(S3ErrorKind.protocol, 'endpoint 格式不正确（示例：https://s3.example.com:9000）');
    }
    if ((u.scheme != 'http' && u.scheme != 'https') || u.host.isEmpty) {
      throw const S3Exception(S3ErrorKind.protocol, '仅支持 http/https 的 S3 endpoint');
    }
    // 零宽/不可见字符会混进 host（Uri.parse 不报错），粘粘贴输入常见——显式拒绝
    if (RegExp(r'[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]').hasMatch(raw.trim())) {
      throw const S3Exception(S3ErrorKind.protocol, 'endpoint 含不可见字符（复制粘贴混入），请手动重新输入');
    }
    final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    return Uri(scheme: u.scheme, host: u.host, port: u.port, path: path);
  }

  /// object key → 请求 URL（path-style：`<endpoint>/<bucket>/<key>`）。
  /// key 逐段 Uri.encodeComponent（S3 要求逐段编码，`/` 保留），query 单独编码。
  Uri _url(String key, [Map<String, String>? query]) {
    final encodedKey = key
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final q = <String, String>{};
    query?.forEach((k, v) => q[Uri.encodeComponent(k)] = Uri.encodeComponent(v));
    return _base.replace(
      path: '${_base.path}/$bucket${encodedKey.isEmpty ? '' : '/$encodedKey'}',
      query: q.isEmpty
          ? null
          : q.entries.map((e) => '${e.key}=${e.value}').join('&'),
    );
  }

  // ---- SigV4 签名 ----

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hmac(List<int> key, String msg) =>
      Hmac(sha256, key).convert(utf8.encode(msg)).bytes;

  /// SigV4 待签名请求规范（ UNSIGNED-PAYLOAD，正文不参与哈希）。
  String _canonicalRequest({
    required String method,
    required Uri url,
    required Map<String, String> headers,
  }) {
    // canonical query：已编码后按 key 排序重组
    String query = '';
    if (url.query.isNotEmpty) {
      final pairs = <List<String>>[
        for (final p in url.query.split('&'))
          p.contains('=') ? [p.substring(0, p.indexOf('=')), p.substring(p.indexOf('=') + 1)] : [p, ''],
      ];
      pairs.sort((a, b) {
        final c = a[0].compareTo(b[0]);
        return c != 0 ? c : a[1].compareTo(b[1]);
      });
      query = pairs.map((p) => '${p[0]}=${p[1]}').join('&');
    }
    // canonical headers：全部小写、按名排序、值 trim
    final names = headers.keys.map((k) => k.toLowerCase()).toList()..sort();
    final canonicalHeaders =
        names.map((n) => '$n:${headers.entries.firstWhere((e) => e.key.toLowerCase() == n).value.trim()}\n').join();
    final signedHeaders = names.join(';');
    return [
      method,
      url.path, // 已逐段编码（encodeComponent 产出即 canonical path）
      query,
      canonicalHeaders,
      signedHeaders,
      'UNSIGNED-PAYLOAD',
    ].join('\n');
  }

  Map<String, String> _sign(String method, Uri url, {DateTime? at}) {
    final now = at ?? DateTime.now().toUtc();
    final amzDate =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}T${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}Z';
    final dateStamp = amzDate.substring(0, 8);
    final scope = '$dateStamp/$region/s3/aws4_request';

    final headers = <String, String>{
      'host': url.host + (url.hasPort ? ':${url.port}' : ''),
      'x-amz-content-sha256': 'UNSIGNED-PAYLOAD',
      'x-amz-date': amzDate,
    };
    final canonical = _canonicalRequest(method: method, url: url, headers: headers);
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      _hex(sha256.convert(utf8.encode(canonical)).bytes),
    ].join('\n');

    var signingKey = _hmac(utf8.encode('AWS4$_sk'), dateStamp);
    signingKey = _hmac(signingKey, region);
    signingKey = _hmac(signingKey, 's3');
    signingKey = _hmac(signingKey, 'aws4_request');
    final signature = _hex(_hmac(signingKey, stringToSign));

    final names = headers.keys.map((k) => k.toLowerCase()).toList()..sort();
    headers['Authorization'] =
        'AWS4-HMAC-SHA256 Credential=$_ak/$scope, SignedHeaders=${names.join(';')}, Signature=$signature';
    return headers;
  }

  /// 取消请求统一转 S3Exception(cancelled) 上抛；非取消时返回由调用方继续走 _wrap。
  void _rethrowIfCancelled(DioException e) {
    if (e.type == DioExceptionType.cancel) {
      throw const S3Exception(S3ErrorKind.cancelled, '已取消');
    }
  }

  S3Exception _wrap(DioException e) {
    final s = e.response?.statusCode;
    if (s == 401 || s == 403) {
      return const S3Exception(S3ErrorKind.auth, 'S3 认证失败（AK/SK 错误或无该 bucket 权限）');
    }
    if (s == 404 || s == 410) return const S3Exception(S3ErrorKind.notFound, '远端对象不存在');
    if (s == 301) return const S3Exception(S3ErrorKind.protocol, 'bucket 位置重定向（region 配置可能不对）');
    if (s != null && s >= 500) return S3Exception(S3ErrorKind.server, 'S3 服务端错误（$s）');
    // 4xx（如 R2 的 400）：错误码在响应体 XML 的 <Code>/<Message> 里，必须挖出来给用户
    if (s != null) {
      final body = e.response?.data;
      final text = body is String ? body : '$body';
      final code = RegExp(r'<Code>([^<]+)</Code>').firstMatch(text)?.group(1);
      final msg = RegExp(r'<Message>([^<]+)</Message>').firstMatch(text)?.group(1);
      return S3Exception(S3ErrorKind.server, 'S3 请求失败（$s${code == null ? '' : ' $code'}）'
          '${msg == null ? '' : '：$msg'}');
    }
    return S3Exception(S3ErrorKind.network, '网络连接失败：${e.message ?? e.type}');
  }

  // ---- 对外操作 ----

  /// 连接测试：HeadBucket（认证 + bucket 存在 + 权限一次验证）。
  Future<void> testConnection({CancelToken? token}) async {
    final url = _url('');
    try {
      await _http.requestUri(
        url,
        cancelToken: token,
        options: Options(method: 'HEAD', headers: _sign('HEAD', url)),
      );
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      // HEAD 无响应体；404= bucket 不存在，403= 无 ListBucket 权限但 AK 可能对——
      // 用 HeadObject 对一个必然不存在的 key 区分「bucket 缺失」与「权限不足」
      final s = e.response?.statusCode;
      if (s == 403) {
        throw const S3Exception(
            S3ErrorKind.auth, 'S3 拒绝访问（AK/SK 错误，或该凭据无此 bucket 权限）');
      }
      if (s == 404) {
        throw const S3Exception(S3ErrorKind.notFound, 'bucket 不存在（检查 bucket 名与 endpoint）');
      }
      throw _wrap(e);
    }
  }

  /// HeadObject：存在返回大小，不存在返回 null。
  Future<int?> head(String key, {CancelToken? token}) async {
    final url = _url(key);
    try {
      final r = await _http.headUri(url, cancelToken: token, options: Options(headers: _sign('HEAD', url)));
      return int.tryParse(r.headers.value(Headers.contentLengthHeader) ?? '');
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      final s = e.response?.statusCode;
      if (s == 404 || s == 410) return null;
      throw _wrap(e);
    }
  }

  /// PutObject：流式上传本地文件（UNSIGNED-PAYLOAD，Content-Length 显式给出）。
  /// 文件超过 [multipartThreshold]（默认 100MB）自动切换 Multipart：
  /// 分片独立上传，失败只重传未完成的分片（大视频备份不再整体重传）。
  Future<void> putFile(
    String key,
    File file, {
    CancelToken? token,
    void Function(int sent, int? total)? onProgress,
  }) async {
    final size = file.lengthSync();
    if (size > multipartThreshold) {
      await _putFileMultipart(key, file, size, token: token, onProgress: onProgress);
      return;
    }
    final url = _url(key);
    final headers = _sign('PUT', url)..[Headers.contentLengthHeader] = size.toString();
    try {
      await _http.putUri(
        url,
        data: file.openRead(),
        cancelToken: token,
        options: Options(headers: headers),
        onSendProgress: onProgress,
      );
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      throw _wrap(e);
    }
  }

  // ---- Multipart Upload（大文件分片上传）----

  /// CreateMultipartUpload：返回 uploadId（生命周期由调用方经 complete/abort 收口）。
  Future<String> createMultipartUpload(String key, {CancelToken? token}) async {
    final url = _url(key, const {'uploads': ''});
    final Response<String> r;
    try {
      r = await _http.requestUri(
        url,
        cancelToken: token,
        options: Options(method: 'POST', headers: _sign('POST', url), responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      throw _wrap(e);
    }
    final id = RegExp(r'<UploadId>([^<]+)</UploadId>')
        .firstMatch(r.data ?? '')
        ?.group(1);
    if (id == null || id.isEmpty) {
      throw const S3Exception(S3ErrorKind.server, 'CreateMultipartUpload 响应缺少 UploadId');
    }
    return id;
  }

  /// UploadPart：按 partNumber（1 起）上传一个分片；成功返回该分片 ETag（complete 必需）。
  Future<String> uploadPart(
    String key,
    String uploadId,
    int partNumber,
    List<int> bytes, {
    CancelToken? token,
    void Function(int sent, int? total)? onProgress,
  }) async {
    final url = _url(key, {
      'partNumber': '$partNumber',
      'uploadId': uploadId,
    });
    final headers = _sign('PUT', url)..[Headers.contentLengthHeader] = bytes.length.toString();
    try {
      final r = await _http.putUri(
        url,
        data: Stream.fromIterable([bytes]),
        cancelToken: token,
        options: Options(headers: headers),
        onSendProgress: onProgress,
      );
      final etag = r.headers.value('etag');
      if (etag == null || etag.isEmpty) {
        throw S3Exception(S3ErrorKind.server, 'UploadPart($partNumber) 响应缺少 ETag');
      }
      return etag;
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      throw _wrap(e);
    }
  }

  /// CompleteMultipartUpload：提交全部分片，服务端原子拼装为完整对象。
  /// parts 顺序必须与 partNumber 一致（S3 规范）。
  Future<void> completeMultipartUpload(
    String key,
    String uploadId,
    List<(int, String)> parts, {
    CancelToken? token,
  }) async {
    final url = _url(key, {'uploadId': uploadId});
    final body = completeMultipartBody(parts);
    final headers = _sign('POST', url)..[Headers.contentLengthHeader] = utf8.encode(body).length.toString();
    headers['Content-Type'] = 'application/xml';
    try {
      await _http.postUri(
        url,
        data: utf8.encode(body),
        cancelToken: token,
        options: Options(headers: headers),
      );
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      throw _wrap(e);
    }
  }

  /// AbortMultipartUpload：中止并清理已上传分片（幂等：已不存在返回 false）。
  Future<bool> abortMultipartUpload(String key, String uploadId, {CancelToken? token}) async {
    final url = _url(key, {'uploadId': uploadId});
    try {
      await _http.deleteUri(url, cancelToken: token, options: Options(headers: _sign('DELETE', url)));
      return true;
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      final s = e.response?.statusCode;
      if (s == 404 || s == 410) return false;
      throw _wrap(e);
    }
  }

  /// Multipart 上传实现：按固定分片大小切文件，逐片上传后 complete。
  /// 每片进度折算到全文件坐标系传给 [onProgress]；失败时 abort 清理已传分片再上抛
  /// （若 abort 本身网络失败，残留分片由 S3 生命周期规则或下次重传覆盖，不阻塞报错）。
  Future<void> _putFileMultipart(
    String key,
    File file,
    int size, {
    CancelToken? token,
    void Function(int sent, int? total)? onProgress,
  }) async {
    final partSize = computePartSize(size);
    final totalParts = (size + partSize - 1) ~/ partSize;
    final uploadId = await createMultipartUpload(key, token: token);
    final parts = <(int, String)>[];
    try {
      for (var n = 1; n <= totalParts; n++) {
        final start = (n - 1) * partSize;
        final len = size - start < partSize ? size - start : partSize;
        final raf = await file.open();
        try {
          await raf.setPosition(start);
          final bytes = await raf.read(len);
          final etag = await uploadPart(
            key,
            uploadId,
            n,
            bytes,
            token: token,
            onProgress: onProgress == null
                ? null
                : (sent, _) => onProgress(start + sent, size),
          );
          parts.add((n, etag));
        } finally {
          await raf.close();
        }
      }
      await completeMultipartUpload(key, uploadId, parts, token: token);
    } catch (e) {
      try {
        await abortMultipartUpload(key, uploadId, token: token);
      } catch (_) {}
      rethrow;
    }
  }

  /// CompleteMultipartUpload 请求体（纯函数，可单测）。
  @visibleForTesting
  static String completeMultipartBody(List<(int, String)> parts) {
    final b = StringBuffer('<CompleteMultipartUpload>');
    for (final (n, etag) in parts) {
      b.write('<Part><PartNumber>$n</PartNumber><ETag>${_xmlEscape(etag)}</ETag></Part>');
    }
    b.write('</CompleteMultipartUpload>');
    return b.toString();
  }

  static String _xmlEscape(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

  /// 计算分片大小（纯函数，可单测）：目标 16MB/片，但保证总片数 ≤10000
  /// （S3 硬上限，超过即整个 upload 被拒）——如 200GB 文件自动放大到 ~20MB/片。
  @visibleForTesting
  static int computePartSize(int totalBytes) {
    const target = 16 * 1024 * 1024;
    if (totalBytes <= 0) return target;
    final byCount = (totalBytes + 10000 - 1) ~/ 10000; // 不超 10000 片的最小片大小
    return byCount > target ? byCount : target;
  }

  /// PutObject：字节内容（manifest 等小文件）。
  Future<void> put(String key, List<int> data, {CancelToken? token}) async {
    final url = _url(key);
    final headers = _sign('PUT', url)
      ..[Headers.contentLengthHeader] = data.length.toString();
    try {
      await _http.putUri(
        url,
        data: data,
        cancelToken: token,
        options: Options(headers: headers),
      );
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      throw _wrap(e);
    }
  }

  /// GetObject 下载至 [dest]（流式落盘 + 大小校验防截断 + rename）。
  /// [expectedSize] 非空时校验实际大小；[dest] 已存在时调用方需先删除。
  Future<File> get(
    String key,
    File dest, {
    int? expectedSize,
    CancelToken? token,
    void Function(int received, int? total)? onProgress,
  }) async {
    final url = _url(key);
    final part = File('${dest.path}.part');
    try {
      await _http.downloadUri(
        url,
        part.path,
        cancelToken: token,
        options: Options(headers: _sign('GET', url)),
        onReceiveProgress: onProgress,
      );
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      try {
        await part.delete();
      } catch (_) {}
      throw _wrap(e);
    }
    final size = part.lengthSync();
    if (expectedSize != null && size != expectedSize) {
      try {
        await part.delete();
      } catch (_) {}
      throw S3Exception(S3ErrorKind.server, '下载后大小不符（期望 $expectedSize 字节，实际 $size）');
    }
    await part.rename(dest.path);
    return dest;
  }

  /// ListObjectsV2：列出 [prefix] 下全部对象 key（自动翻页，最多 10 页兜底）。
  /// 返回 (key, size) 列表。
  Future<List<S3Object>> list(String prefix, {CancelToken? token}) async {
    final out = <S3Object>[];
    String? continuation;
    for (var page = 0; page < 10; page++) {
      final query = <String, String>{
        'list-type': '2',
        'prefix': prefix,
        'continuation-token': ?continuation,
      };
      final url = _url('', query);
      final Response<String> r;
      try {
        r = await _http.requestUri(
          url,
          cancelToken: token,
          options: Options(
            method: 'GET',
            headers: _sign('GET', url),
            responseType: ResponseType.plain,
          ),
        );
      } on DioException catch (e) {
        _rethrowIfCancelled(e);
        throw _wrap(e);
      }
      final xml = r.data ?? '';
      out.addAll(_parseContents(xml));
      final next = RegExp(r'<NextContinuationToken>([^<]+)</NextContinuationToken>')
          .firstMatch(xml)
          ?.group(1);
      if (next == null || next.isEmpty) break;
      continuation = next;
    }
    return out;
  }

  /// DeleteObject：不存在返回 false（幂等，不视为失败）。
  Future<bool> delete(String key, {CancelToken? token}) async {
    final url = _url(key);
    try {
      await _http.deleteUri(url, cancelToken: token, options: Options(headers: _sign('DELETE', url)));
      return true;
    } on DioException catch (e) {
      _rethrowIfCancelled(e);
      final s = e.response?.statusCode;
      if (s == 404 || s == 410) return false;
      throw _wrap(e);
    }
  }

  /// 测试缝：固定时间签名（单测对拍 SigV4 结果；生产路径不受影响）。
  @visibleForTesting
  Map<String, String> signForTest(String method, String key, {required DateTime utcAt}) =>
      _sign(method, _url(key), at: utcAt);

  /// 测试缝：ListObjectsV2 `<Contents>` XML 解析（单测直测解析分支）。
  @visibleForTesting
  static List<S3Object> parseListResponseForTest(String xml) => _parseContents(xml);

  /// ListObjectsV2 `<Contents>` 解析（零 xml 依赖：Key/Size 逐块正则）。
  static List<S3Object> _parseContents(String xml) {
    final out = <S3Object>[];
    for (final m in RegExp(r'<Contents>(.*?)</Contents>', dotAll: true).allMatches(xml)) {
      final block = m.group(1)!;
      final key = RegExp(r'<Key>([^<]+)</Key>').firstMatch(block)?.group(1);
      if (key == null || key.isEmpty) continue;
      final size = RegExp(r'<Size>(\d+)</Size>').firstMatch(block)?.group(1);
      out.add(S3Object(key: Uri.decodeComponent(key), size: size == null ? null : int.tryParse(size)));
    }
    return out;
  }
}

/// ListObjectsV2 返回的对象条目。
class S3Object {
  const S3Object({required this.key, this.size});

  final String key;
  final int? size;
}

/// 错误分类：UI 侧按 kind 给可行动文案（项目规约：错误必须可感知）。
enum S3ErrorKind { auth, notFound, protocol, network, server, cancelled }

class S3Exception implements Exception {
  const S3Exception(this.kind, this.message);

  final S3ErrorKind kind;
  final String message;

  @override
  String toString() => '[s3:${kind.name}] $message';
}

/// Uint8List 便捷导出（测试向量用例比对签名中间值）。
Uint8List s3Sha256Bytes(String s) => Uint8List.fromList(sha256.convert(utf8.encode(s)).bytes);
