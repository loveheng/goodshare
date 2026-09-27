#!/usr/bin/env node
// goodshare MCP stdio bridge
// 桌面端 MCP 客户端（stdio 传输，如 Claude Desktop / ZCode）↔ 手机端「拾贝」内嵌 MCP 服务（Streamable HTTP）之间的桥。
// 用法：
//   node stdio-bridge.mjs [--url http://127.0.0.1:8765/mcp] [--token <X-Api-Key>]
//   也可用环境变量 GOODSHARE_URL / GOODSHARE_TOKEN（优先级低于命令行参数）。
// USB 场景先执行：adb reverse tcp:8765 tcp:8765
import { createInterface } from 'node:readline';
import process from 'node:process';

const VERSION = '1.0.0';

function help() {
  console.log(`goodshare-mcp-bridge ${VERSION} — 桌面 stdio MCP 客户端 ↔ 手机「拾贝」HTTP MCP 服务桥

用法: node stdio-bridge.mjs [--url <u>] [--token <t>]
  --url    手机端 MCP 端点，默认 \${GOODSHARE_URL:-http://127.0.0.1:8765/mcp}
  --token  X-Api-Key 值（app「MCP 服务」页可查看），默认 \${GOODSHARE_TOKEN:-}

MCP 客户端配置示例（Claude Desktop / ZCode）:
  {
    "mcpServers": {
      "goodshare": {
        "command": "node",
        "args": ["/path/to/stdio-bridge.mjs", "--token", "<app内显示的token>"]
      }
    }
  }`);
}

const argv = process.argv.slice(2);
const flags = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--help' || a === '-h') { help(); process.exit(0); }
  if (a === '--version' || a === '-v') { console.log(`goodshare-mcp-bridge ${VERSION}`); process.exit(0); }
  if (a === '--url') flags.url = argv[++i];
  else if (a === '--token') flags.token = argv[++i];
  else { process.stderr.write(`未知参数: ${a}（--help 查看用法）\n`); process.exit(2); }
}
const ENDPOINT = flags.url || process.env.GOODSHARE_URL || 'http://127.0.0.1:8765/mcp';
const TOKEN = flags.token ?? process.env.GOODSHARE_TOKEN ?? '';

let sessionId = null;

async function postUpstream(text) {
  const headers = { 'content-type': 'application/json', 'accept': 'application/json, text/event-stream' };
  if (TOKEN) headers['x-api-key'] = TOKEN;
  if (sessionId) headers['mcp-session-id'] = sessionId;
  const res = await fetch(ENDPOINT, { method: 'POST', headers, body: text });
  const sid = res.headers.get('mcp-session-id');
  if (sid) sessionId = sid;
  return res;
}

function parseSse(body) {
  const out = [];
  for (const block of body.split(/\r?\n\r?\n/)) {
    const data = block.split(/\r?\n/).filter((l) => l.startsWith('data:')).map((l) => l.slice(5).trim()).join('\n');
    if (data) out.push(data);
  }
  return out;
}

function reply(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

async function handle(line) {
  let msg;
  try { msg = JSON.parse(line); } catch {
    reply({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
    return;
  }
  let res;
  try { res = await postUpstream(line); } catch (e) {
    if (msg.id !== undefined && msg.id !== null) {
      reply({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: 'Bridge upstream error', data: String(e?.message || e) } });
    }
    return;
  }
  const body = await res.text();
  if (res.status === 202 || body === '') return; // notification：stdio 侧本就无需应答
  const ctype = res.headers.get('content-type') || '';
  let payloads = [];
  if (ctype.includes('text/event-stream')) {
    payloads = parseSse(body);
  } else {
    payloads = [body];
  }
  for (const p of payloads) {
    try { reply(JSON.parse(p)); } catch {
      reply({ jsonrpc: '2.0', id: msg.id ?? null, error: { code: -32603, message: `Upstream HTTP ${res.status}，响应非 JSON-RPC`, data: p.slice(0, 300) } });
    }
  }
}

const queue = [];
let draining = false;
async function drain() {
  if (draining) return;
  draining = true;
  try { while (queue.length) await handle(queue.shift()); } finally { draining = false; }
}

const rl = createInterface({ input: process.stdin, terminal: false });
rl.on('line', (l) => { const t = l.trim(); if (!t) return; queue.push(t); drain(); });
rl.on('close', () => process.exit(0));
