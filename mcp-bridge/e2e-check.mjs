#!/usr/bin/env node
// 桥接端到端自检：mock 一个 MCP HTTP 上游，拉起 stdio-bridge.mjs，
// 从 stdin 发 initialize / tools/list / tools/call，断言响应与 session/token 透传。
// 用法：node mcp-bridge/e2e-check.mjs   （exit 0 = 通过）
import { spawn } from 'node:child_process';
import http from 'node:http';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const bridge = resolve(here, 'stdio-bridge.mjs');
const TOKEN = 'e2e-token';

let sawSessionHeader = false;
let sawTokenHeader = false;

const upstream = http.createServer((req, res) => {
  if (req.headers['x-api-key'] === TOKEN) sawTokenHeader = true;
  if (req.headers['mcp-session-id'] === 'sess-1') sawSessionHeader = true;
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const msg = JSON.parse(body);
    if (msg.id === undefined || msg.id === null) {
      res.writeHead(202);
      res.end();
      return;
    }
    const result =
      msg.method === 'initialize'
        ? { protocolVersion: '2025-06-18', serverInfo: { name: 'mock' } }
        : msg.method === 'tools/list'
          ? { tools: [{ name: 'mock_tool' }] }
          : msg.method === 'tools/call'
            ? { content: [{ type: 'text', text: 'ok' }] }
            : null;
    if (result === null) {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32601, message: 'nope' } }));
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': 'sess-1' });
    res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }));
  });
});

function rpc(proc, obj) {
  proc.stdin.write(JSON.stringify(obj) + '\n');
}

function readLine(proc, timeoutMs = 5000) {
  return new Promise((resolvePromise, rejectPromise) => {
    let buf = '';
    const timer = setTimeout(() => {
      proc.stdout.off('data', onData);
      rejectPromise(new Error('响应超时'));
    }, timeoutMs);
    const onData = (chunk) => {
      buf += chunk.toString();
      const idx = buf.indexOf('\n');
      if (idx >= 0) {
        clearTimeout(timer);
        proc.stdout.off('data', onData);
        resolvePromise(JSON.parse(buf.slice(0, idx)));
      }
    };
    proc.stdout.on('data', onData);
  });
}

const port = 20000 + Math.floor(Math.random() * 20000);
await new Promise((r) => upstream.listen(port, '127.0.0.1', r));

const proc = spawn(
  process.execPath,
  [bridge, '--url', `http://127.0.0.1:${port}/mcp`, '--token', TOKEN],
  { stdio: ['pipe', 'pipe', 'inherit'] },
);

let failures = 0;
const check = (name, cond, extra = '') => {
  console.log(`${cond ? 'PASS' : 'FAIL'}  ${name}${cond ? '' : `  ${extra}`}`);
  if (!cond) failures++;
};

try {
  rpc(proc, { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } });
  const init = await readLine(proc);
  check('initialize 应答', init?.result?.protocolVersion === '2025-06-18', JSON.stringify(init).slice(0, 120));

  rpc(proc, { jsonrpc: '2.0', method: 'notifications/initialized' });
  rpc(proc, { jsonrpc: '2.0', id: 2, method: 'tools/list' });
  const tools = await readLine(proc);
  check('tools/list 应答', tools?.result?.tools?.[0]?.name === 'mock_tool', JSON.stringify(tools).slice(0, 120));

  rpc(proc, { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'mock_tool', arguments: {} } });
  const call = await readLine(proc);
  check('tools/call 应答', call?.result?.content?.[0]?.text === 'ok', JSON.stringify(call).slice(0, 120));

  await new Promise((r) => setTimeout(r, 150));
  check('X-Api-Key 已透传', sawTokenHeader);
  check('Mcp-Session-Id 已回传', sawSessionHeader);
} catch (e) {
  check('无异常', false, e.message);
} finally {
  proc.kill();
  upstream.close();
}

console.log(failures === 0 ? 'E2E PASS' : `E2E FAIL（${failures} 项）`);
process.exit(failures === 0 ? 0 : 1);
