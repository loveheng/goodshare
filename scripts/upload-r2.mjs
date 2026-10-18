#!/usr/bin/env node
// upload-r2.mjs — 零依赖操作 Cloudflare R2（AWS SigV4，region=auto）
// 用法:
//   上传: node scripts/upload-r2.mjs <localFile> <remoteKey> [contentType]
//   删除: node scripts/upload-r2.mjs --delete <remoteKey>
//   读取: node scripts/upload-r2.mjs --get <remoteKey>            # 打印对象内容到 stdout
// 凭证/桶从环境变量读取: R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
// 注: 列举(list)需要 s3:ListBucket 权限；若令牌仅授予 Object Read/Write（无 ListBucket），
//     请用 --get 读取已知对象（如更新清单）来定位待删旧包，避免依赖列举。
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, createHmac } from 'node:crypto';
import { execFile, execFileSync } from 'node:child_process';

const args = process.argv.slice(2);
let mode = 'upload';
let localPath, remoteKey, contentType = 'application/octet-stream';
if (args[0] === '--delete') {
  mode = 'delete';
  remoteKey = args[1];
} else if (args[0] === '--get') {
  mode = 'get';
  remoteKey = args[1];
} else {
  mode = 'upload';
  localPath = args[0];
  remoteKey = args[1];
  if (args[2]) contentType = args[2];
}

function usage() {
  console.error('用法:');
  console.error('  上传: node scripts/upload-r2.mjs <localFile> <remoteKey> [contentType]');
  console.error('  删除: node scripts/upload-r2.mjs --delete <remoteKey>');
  console.error('  读取: node scripts/upload-r2.mjs --get <remoteKey>');
  process.exit(2);
}
if (mode === 'upload' && (!localPath || !remoteKey)) usage();
if (mode === 'delete' && !remoteKey) usage();

const accountId = process.env.R2_ACCOUNT_ID;
const ak = process.env.R2_ACCESS_KEY_ID;
const sk = process.env.R2_SECRET_ACCESS_KEY;
const bucket = process.env.R2_BUCKET;
if (!accountId || !ak || !sk || !bucket) {
  console.error('FAIL: 缺少 R2 环境变量（R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET）');
  process.exit(1);
}

const EMPTY_HASH = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

function hmac(key, data) {
  return createHmac('sha256', key).update(data).digest();
}
function sha256hex(s) {
  return createHash('sha256').update(s).digest('hex');
}

// RFC3986 编码：仅 A-Za-z0-9-_.~ 不编码（含 / → %2F），与请求 URL 保持同一份编码
function encodeRfc3986(s) {
  return encodeURIComponent(s).replace(/[!*'()]/g, (c) => ({
    '!': '%21', '*': '%2A', "'": '%27', '(': '%28', ')': '%29',
  }[c]));
}

// 生成 SigV4 Authorization 头所需字段。bodyHash: PUT 用 UNSIGNED-PAYLOAD，GET/DELETE 用空串哈希
// 返回 canonicalQuery（已编码），调用方须用同一份编码拼到请求 URL 上
function sign(method, key, query, bodyHash) {
  const host = `${accountId}.r2.cloudflarestorage.com`;
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const canonicalHeaders = `host:${host}\nx-amz-content-sha256:${bodyHash}\nx-amz-date:${amzDate}\n`;
  const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
  // 规范查询串：按 key=value 拆分、RFC3986 编码、排序（S3 会解码 %2F 还原前缀 /）
  const canonicalQuery = query
    ? query.split('&').filter(Boolean).map((p) => {
        const i = p.indexOf('=');
        const k = i < 0 ? p : p.slice(0, i);
        const v = i < 0 ? '' : p.slice(i + 1);
        return `${encodeRfc3986(k)}=${encodeRfc3986(v)}`;
      }).sort().join('&')
    : '';
  const canonicalRequest =
    `${method}\n/${bucket}/${key}\n${canonicalQuery}\n${canonicalHeaders}\n${signedHeaders}\n${bodyHash}`;
  const algorithm = 'AWS4-HMAC-SHA256';
  const credentialScope = `${dateStamp}/auto/s3/aws4_request`;
  const stringToSign = `${algorithm}\n${amzDate}\n${credentialScope}\n${sha256hex(canonicalRequest)}`;
  const signingKey = hmac(hmac(hmac(hmac(`AWS4${sk}`, dateStamp), 'auto'), 's3'), 'aws4_request');
  const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex');
  const authorization =
    `${algorithm} Credential=${ak}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  return { authorization, amzDate, host };
}

try {
  execFileSync('curl', ['--version'], { stdio: 'ignore' });
} catch {
  console.error('FAIL: 需要 curl（受限沙箱内 node fetch 直连 Cloudflare 易 ETIMEDOUT，curl 更稳）');
  process.exit(1);
}

// 统一传输层：用 curl 发 SigV4 请求；GET 可选把响应体写文件（outFile）
function curlSend(method, key, query, outFile) {
  const bodyHash = method === 'PUT' ? 'UNSIGNED-PAYLOAD' : EMPTY_HASH;
  const { authorization, amzDate, host, canonicalQuery } = sign(method, key, query, bodyHash);
  const url = `https://${host}/${bucket}/${key}${canonicalQuery ? '?' + canonicalQuery : ''}`;
  const curlArgs = [
    '-sS', '-X', method, '-w', '%{http_code}',
    '--connect-timeout', '30', '--retry', '3',
    '-H', `Authorization: ${authorization}`,
    '-H', `x-amz-date: ${amzDate}`,
    '-H', `x-amz-content-sha256: ${bodyHash}`,
  ];
  if (method === 'PUT') {
    curlArgs.push('-H', `Content-Type: ${contentType}`, '--data-binary', `@${localPath}`);
  } else if (contentType && contentType !== 'application/octet-stream') {
    curlArgs.push('-H', `Content-Type: ${contentType}`);
  }
  curlArgs.push(outFile ? '-o' : '-o', outFile || '/dev/null');
  curlArgs.push(url);
  return new Promise((resolve, reject) => {
    execFile('curl', curlArgs, { maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
      if (err) return reject(new Error(`curl 失败: ${stderr || err.message}`));
      resolve(stdout.trim());
    });
  });
}

if (mode === 'get') {
  const out = join(tmpdir(), 'r2-get.json');
  const code = await curlSend('GET', remoteKey, '', out).catch((e) => {
    console.error(`FAIL: ${e.message}`);
    process.exit(1);
  });
  if (!(code >= 200 && code < 300)) {
    console.error(`FAIL: 读取失败 HTTP ${code}`);
    process.exit(1);
  }
  process.stdout.write(readFileSync(out, 'utf8'));
  process.exit(0);
}

if (mode === 'delete') {
  const code = await curlSend('DELETE', remoteKey, '').catch((e) => {
    console.error(`FAIL: ${e.message}`);
    process.exit(1);
  });
  // 2xx = 删除成功；404 = 本就不存在（视为已清理，不报错）
  if ((code >= 200 && code < 300) || code === 404) {
    console.log(`OK: 删除 s3://${bucket}/${remoteKey} (HTTP ${code})`);
    process.exit(0);
  }
  console.error(`FAIL: 删除失败 HTTP ${code}`);
  process.exit(1);
}

// 默认：上传（零依赖 Node 脚本，AWS SigV4 直传 R2）
const code = await curlSend('PUT', remoteKey, '').catch((e) => {
  console.error(`FAIL: ${e.message}`);
  process.exit(1);
});
if (!(code >= 200 && code < 300)) {
  console.error(`FAIL: 上传失败 HTTP ${code}`);
  process.exit(1);
}
console.log(`OK: 上传 ${localPath} → s3://${bucket}/${remoteKey}`);
