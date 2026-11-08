#!/usr/bin/env node
/**
 * 真机 AI 能力自动化验收（试点）：摘要 / 分类（标签）。
 *
 * 测的是生产链路，不是 mock：
 *   PC 经 goodshare 的 loopback MCP 服务造条目并入队
 *   → goodhub 宿主上线 catch-up（Binder 本地插件 claim_ai_task）
 *   → 宿主 LLM 推理并 apply_ai_result 回写
 *   → PC 再经 MCP 读回条目与任务终态做断言。
 *
 * 分层契约（docs/design/ai-e2e-pilot.md）：
 *   - 设备发现 / token / 端点透传一律复用 scripts/agent-tools/debug-bridge.sh；
 *   - 本文件只做用例编排、语义等待、断言与报告，不复制到处拼的 adb 胶水；
 *   - 触发消费走「宿主上线 catch-up」这一生产语义，不往业务管线塞测试专用分支；
 *   - 令牌只在进程内存，绝不写报告、日志或代码。
 *
 * 用法：node scripts/e2e/ai-capability-e2e.mjs [--device <SERIAL>] [--case all|summary|tags|ondevice]
 *       [--timeout <秒>] [--repeat <N>] [--keep] [--precheck] [--self-test] [--report <path>]
 */
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '../..');
const DBG = resolve(ROOT, 'scripts/agent-tools/debug-bridge.sh');
const GOODSHARE = 'com.zzh.goodshare';
const GOODHUB = 'com.zzh.goodhub';
const MCP_URL = 'http://127.0.0.1:8765/mcp';
const MCP_PORT = 8765;
const REPORT_DIR = resolve(ROOT, 'build/e2e');

const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const flag = (...names) => names.some((n) => argv.includes(n));

const caseFilter = opt('--case', 'all');
const repeat = Math.max(1, Number(opt('--repeat', '1')) || 1);
const timeoutSec = Number(opt('--timeout', '120'));
const keep = flag('--keep');
const selfTestOnly = flag('--self-test');
const precheckOnly = flag('--precheck');
const reportPath = resolve(opt('--report', resolve(REPORT_DIR, 'ai-capability-report.json')));

const SAMPLE_TEXT =
  '拾贝是一款运行在安卓手机上的分享收集器，可以把微信和浏览器分享的文章、链接、图片统一收进收件箱，' +
  '并在设备上生成摘要、标签与字幕。AI 能力由宿主应用通过本地插件认领任务完成，推理结果经 MCP 回写到条目，' +
  '人和 AI 读到同一份状态。';

let device = opt('--device', '');
let mcpToken = '';
let rpcId = 0;
let triggerCount = 0;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isoNow = () => new Date().toISOString();

function run(cmd, args, options = {}) {
  return execFileSync(cmd, args, {
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
    ...options,
  });
}

function adb(...args) {
  return run('adb', ['-s', device, ...args]).trim();
}

/** 薄管道 CLI 单次调用；失败把 stderr 的 remedy 带出来，不吞异常。 */
function dbg(pkg, ...cmd) {
  try {
    const out = run('bash', [DBG, '--device', device, '--package', pkg, ...cmd]);
    return JSON.parse(out.trim());
  } catch (e) {
    const detail = `${e.stderr || ''}${e.stdout || ''}`.toString().trim().slice(-600);
    throw new Error(`debug-bridge(${pkg} ${cmd.join(' ')}) 失败：${detail || e.message}`);
  }
}

/** 同 dbg 但放宽 HTTP 超时（慢动作：drain_supply_pool 同步等端侧推理完成）。 */
function dbgEnv(pkg, env, ...cmd) {
  try {
    const out = run('bash', [DBG, '--device', device, '--package', pkg, ...cmd], {
      env: { ...process.env, ...env },
    });
    return JSON.parse(out.trim());
  } catch (e) {
    const detail = `${e.stderr || ''}${e.stdout || ''}`.toString().trim().slice(-600);
    throw new Error(`debug-bridge(${pkg} ${cmd.join(' ')}) 失败：${detail || e.message}`);
  }
}

/** 同 dbg 但返回原文（非 JSON 输出的命令：tap_text 等带 [tag] 前缀行）。 */
function dbgRaw(pkg, ...cmd) {
  return run('bash', [DBG, '--device', device, '--package', pkg, ...cmd]).trim();
}

async function rpc(method, params) {
  const headers = { 'content-type': 'application/json' };
  if (mcpToken) headers['x-api-key'] = mcpToken;
  let res;
  try {
    res = await fetch(MCP_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
      signal: AbortSignal.timeout(20000),
    });
  } catch (e) {
    throw new Error(`MCP 请求不可达（${method}）：${e.message}；检查 adb forward tcp:${MCP_PORT} 与 MCP 服务开关`);
  }
  const body = await res.json();
  if (!res.ok || body.error) {
    const err = body.error ? JSON.stringify(body.error) : `HTTP ${res.status}`;
    throw new Error(`MCP ${method} 失败：${err}`);
  }
  return body.result;
}

/** tools/call 信封解包：content[0].text 是业务 JSON 字符串。 */
async function tool(name, args) {
  const result = await rpc('tools/call', { name, arguments: args });
  if (result?.isError) {
    throw new Error(`工具 ${name} 返回 isError：${JSON.stringify(result.content).slice(0, 300)}`);
  }
  const text = result?.content?.[0]?.text;
  if (typeof text !== 'string') throw new Error(`工具 ${name} 缺少 content[0].text`);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

// ───────────────────────── 断言（纯函数，可自测） ─────────────────────────

/** 通用护栏：任务终态、原文不被覆盖、版本递增、失败原因不得被静默吞掉。 */
function commonProblems(before, after, job, action, enqueued) {
  const problems = [];
  if (!job?.found) problems.push(`任务不可查（get_job_status.found=false）：${JSON.stringify(job)}`);
  if (job?.status !== 'completed') {
    problems.push(`任务终态不是 completed：${job?.status ?? 'unknown'}${job?.note ? ` note=${job.note}` : ''}`);
  }
  if (job?.action && job.action !== action) problems.push(`任务动作不符：期望 ${action}，实际 ${job.action}`);
  if (before.text !== after.text) problems.push('原文被 AI 回写覆盖');
  // 入队命令本身会写 is_processed=0 并递增 version；回写是否发生须以
  // 「入队后快照」为基准，不能拿造条目后的旧 version 比。
  const baseline = enqueued ?? before;
  if (!(Number(after.version) > Number(baseline.version))) {
    problems.push(`version 未递增（入队后 ${baseline.version} → ${after.version}）`);
  }
  return problems;
}

function checkSummary(before, after, job, enqueued) {
  const problems = commonProblems(before, after, job, 'llm_summarize', enqueued);
  const summary = typeof after.summary === 'string' ? after.summary.trim() : '';
  if (!summary) problems.push('get_item.summary 为空（无产出）');
  if (summary && summary === String(after.text ?? '').trim()) problems.push('summary 与原文逐字相同（占位回写）');
  if (summary.length < 20) problems.push(`summary 过短（${summary.length} 字）`);
  if (after.summary_stale === true) problems.push('summary_stale=true（正文锚未同步）');
  return problems;
}

/** 标签形态护栏：关键词是短词，不是整段文本被分隔符切碎后的碎片。 */
function isBadTag(tag) {
  const s = String(tag ?? '').trim();
  if (s.length === 0 || s.length > 24) return true;
  if (/[\r\n*#|`>\[\]{}()（）:：。！!?？]/.test(s)) return true;
  return (s.match(/\s/g) ?? []).length > 2;
}

/** 标签校验由数据 owner（goodshare 动作层）执行，故 tags 用例有两条正确终态。 */
function tagsGuardTriggered(job) {
  return job?.status === 'failed' &&
    String(job?.note ?? '').includes('标签形态不合规');
}

function checkTags(before, after, job, enqueued) {
  const problems = [];
  if (!job?.found) problems.push(`任务不可查（get_job_status.found=false）：${JSON.stringify(job)}`);
  if (job?.action && job.action !== 'llm_tags') problems.push(`任务动作不符：期望 llm_tags，实际 ${job.action}`);
  const baseline = enqueued ?? before;
  const baselineTags = Array.isArray(baseline.tags) ? baseline.tags : [];
  const afterTags = Array.isArray(after.tags) ? after.tags : [];
  const added = afterTags.filter((t) => !baselineTags.includes(t));

  // B 护栏生效：宿主产出不合规被数据 owner 整批拒绝。仍须证明失败可观测且
  // 数据干净——随便 failed / note 缺失 / 部分落库都不算 PASS。
  if (tagsGuardTriggered(job)) {
    if (before.text !== after.text) problems.push('护栏触发但原文被改');
    if (Number(after.version) !== Number(baseline.version)) {
      problems.push(`护栏触发但 version 又变了（入队后 ${baseline.version} → ${after.version}），回写未被整批拒绝`);
    }
    if (afterTags.length !== baselineTags.length) problems.push('护栏触发但 tags 数量变了');
    const bad = added.filter(isBadTag);
    if (bad.length) problems.push(`护栏触发但条目仍含 ${bad.length} 个碎片标签`);
    return problems;
  }

  // A 合规产出正常回写：任务 completed、版本递增、标签合规且只增不删。
  if (job?.status !== 'completed') {
    problems.push(`任务终态不是 completed：${job?.status ?? 'unknown'}${job?.note ? ` note=${job.note}` : ''}`);
  }
  if (before.text !== after.text) problems.push('原文被 AI 回写覆盖');
  if (!(Number(after.version) > Number(baseline.version))) {
    problems.push(`version 未递增（入队后 ${baseline.version} → ${after.version}）`);
  }
  if (added.length === 0) problems.push('没有新增标签（无产出）');
  if (added.length > 12) problems.push(`新增标签数异常（${added.length}）：疑似整段文本被切碎`);
  const bad = added.filter(isBadTag);
  if (bad.length > 0) {
    problems.push(`标签形态不合规 ${bad.length} 个：${bad.slice(0, 3).map((t) => JSON.stringify(t)).join(' / ')}`);
  }
  for (const t of baselineTags) {
    if (!afterTags.includes(t)) problems.push(`原有标签被覆盖删除：${t}`);
  }
  return problems;
}

const CASES = [
  {
    id: 'summary',
    label: '摘要（llm_summarize）',
    enqueueTool: 'summarize_item',
    action: 'llm_summarize',
    seedTags: [],
    check: checkSummary,
    evidence: (after) => ({
      summaryLength: String(after.summary ?? '').length,
      summaryStale: after.summary_stale ?? null,
    }),
  },
  {
    id: 'tags',
    label: '分类/标签（llm_tags）',
    enqueueTool: 'extract_tags',
    action: 'llm_tags',
    seedTags: ['e2e-基线'],
    check: checkTags,
    evidence: (after, job) => ({
      tags: Array.isArray(after.tags) ? after.tags : [],
      tagCount: Array.isArray(after.tags) ? after.tags.length : 0,
      badTags: (Array.isArray(after.tags) ? after.tags : []).filter(isBadTag),
      guardTriggered: tagsGuardTriggered(job),
    }),
  },
];

// ───────────────────────── on-device 用例（§G2，W6-a 端侧链路） ─────────────────────────

// 纯断言件（selfTest 覆盖）：登记表 / 任务池投影的结构化判读——
// 状态真源 = goodshare /debug/state.onDeviceTasks（§G1a）+ goodhub pool_dump（§G1b）。
function registryTaskIds(tasks) {
  return (Array.isArray(tasks) ? tasks : []).map((t) => t.taskId);
}
function poolEntryFor(pool, taskId) {
  return (Array.isArray(pool) ? pool : []).find((e) => e.taskId === taskId) ?? null;
}
/** drain 后已消费 = 不再在途（queued/running 都算未消化）。 */
function poolConsumed(entry) {
  return !!entry && ['pendingDelivery', 'delivered', 'failedExhausted', 'expired'].includes(entry.status);
}
function registryResidueProblems(tasks) {
  const n = Array.isArray(tasks) ? tasks.length : 0;
  return n === 0 ? [] : [`端侧登记表残留 ${n} 条（task_clear 清场后再跑）`];
}

const REG_WAIT_MS = 20000; // bolt → deferred 登记回执窗口
const CONVERGE_WAIT_MS = 45000; // Pull 收敛窗口（resume 即时 poll + 12s 重触发兜底）
const ONDEVICE_TITLE = '[AI-E2E] ondevice';

/** ui-tree 全树文本含指定子串（占位卡 / 失败注记存在性断言；语义树含完整 route 栈）。 */
function uiTreeHas(pkg, needle) {
  return JSON.stringify(dbg(pkg, 'ui-tree')).includes(needle);
}

/** 登记表快照（/debug/state.onDeviceTasks，§G1a）：断言「登记数 / 摘登记」的状态真源。 */
function readRegistry() {
  const st = dbg(GOODSHARE, 'state');
  return Array.isArray(st?.app?.onDeviceTasks) ? st.app.onDeviceTasks : [];
}

/** 回前台 dance：goodhub 短暂前台（顺带防冻结）→ goodshare 回前台触发 resume→pollOnce。 */
function pokeResume() {
  adb('shell', 'am', 'start', '-n', `${GOODHUB}/.MainActivity`);
  sleepSyncMs(1500);
  adb('shell', 'am', 'start', '-n', `${GOODSHARE}/.MainActivity`);
}

/** 条件等待：check() 返回 {ok} 即收敛；poke 每 12s 重触发一次（免 30s 盲等）。 */
async function waitForConverge(check, { deadlineMs = CONVERGE_WAIT_MS, poke = null } = {}) {
  const deadline = Date.now() + deadlineMs;
  let lastPoke = Date.now();
  let last = null;
  while (Date.now() < deadline) {
    last = check();
    if (last.ok) return last;
    if (poke && Date.now() - lastPoke > 12000) {
      poke();
      lastPoke = Date.now();
    }
    await sleep(1500);
  }
  return last;
}

/**
 * W6-a 端侧异步链路闭环：冷宿主 bolt → queued 入池 → 占位卡 → drain 消费 →
 * Pull 取回 → stale 收敛（不落库）→ not_found 收敛。全程结构化断言（登记表
 * 快照 + 任务池投影 + ui-tree 文本），无坐标点击。
 */
async function runOnDeviceCase(caseId) {
  const started = Date.now();
  const result = {
    id: caseId,
    caseId,
    round: 1,
    label: '端侧异步链路（queued→占位→drain→stale/not_found 收敛）',
    status: 'FAIL',
    itemId: null,
    jobId: null,
    triggers: 0,
    durationMs: 0,
    problems: [],
    evidence: {},
    cleanup: null,
  };
  const beforeTriggers = triggerCount;
  let created = false;
  try {
    // 0 复位（可重复性）：双 app 在场（桥可发现）→ 离线注入关 + 开关开 +
    // 登记表/任务池清场。
    adb('shell', 'am', 'start', '-n', `${GOODHUB}/.MainActivity`);
    await sleep(3000);
    dbg(GOODSHARE, 'action', 'host_sim', '{"notReady":false}');
    dbg(GOODSHARE, 'action', 'set_caps', '{"onDeviceAsync":true}');
    dbg(GOODSHARE, 'action', 'task_clear');
    dbg(GOODHUB, 'action', 'purge_supply_pool');

    // 1 seed（MCP 通道，与生产同入口）。
    const content = `${SAMPLE_TEXT}\n\n（on-device 自动化样本 ${isoNow()}）`;
    const added = await tool('add_item', { content, title: ONDEVICE_TITLE, tags: [] });
    if (!added?.id) throw new Error(`add_item 未返回 id：${JSON.stringify(added).slice(0, 200)}`);
    created = true;
    result.itemId = added.id;
    const local = await waitLocalQuiescent(added.id);
    if (!local.settled) result.problems.push('本条目本地任务 20s 未终态（不影响端侧链路，仅记录）');
    const seeded = await tool('get_item', { id: added.id });
    const summaryBefore = seeded.summary ?? null;
    result.evidence.versionAtSeed = seeded.version;

    // 2 冷宿主（模型未装载 → bolt 走 failFast → queued 入池）。
    await triggerHost();

    // 3 goodshare 冷启 → 首页 → 点开条目详情（tap_text 文本锚点，免坐标）。
    adb('shell', 'am', 'force-stop', GOODSHARE);
    await sleep(600);
    adb('shell', 'am', 'start', '-n', `${GOODSHARE}/.MainActivity`);
    await sleep(5000);
    dbgRaw(GOODSHARE, 'tap_text', ONDEVICE_TITLE); // 失败即抛（exit≠0）
    const opened = await waitForConverge(
      () => ({ ok: uiTreeHas(GOODSHARE, 'instant-bolt') }),
      { deadlineMs: 15000 },
    );
    if (!opened.ok) throw new Error('详情页未打开（instant-bolt 未在语义树出现）');

    // 4 bolt → queued → 占位卡 + 本地登记（key 锚点 tap_node）。
    const bolt = dbg(GOODSHARE, 'action', 'tap_node', '{"key":"instant-bolt"}');
    if (!bolt?.result?.ok) throw new Error(`instant-bolt 点击失败：${JSON.stringify(bolt).slice(0, 200)}`);
    const reg = await waitForConverge(() => {
      const tasks = readRegistry();
      return { ok: tasks.length === 1, tasks };
    }, { deadlineMs: REG_WAIT_MS });
    if (!reg.ok) throw new Error(`bolt 后 ${REG_WAIT_MS / 1000}s 登记未出现（tasks=${JSON.stringify(reg.tasks).slice(0, 300)}）；查 McpBinderBridge/宿主接线日志`);
    const taskId = reg.tasks[0].taskId;
    result.jobId = taskId;
    result.evidence.queuedReceipt = reg.tasks[0];
    result.evidence.placeholderVisible = uiTreeHas(GOODSHARE, '后台分析中');
    if (!result.evidence.placeholderVisible) result.problems.push('占位卡「后台分析中」未在语义树出现');

    // 5 宿主池对账（§G1b）：任务在池且 queued。信封：端点把 handler 返回包在
    // .result 里（与 tap_node/edit_body 同款双层）。
    const poolQ = dbg(GOODHUB, 'action', 'pool_dump');
    const entryQ = poolEntryFor(poolQ?.result?.pool, taskId);
    result.evidence.poolAtQueue = entryQ;
    if (!entryQ) throw new Error(`宿主任务池无 ${taskId}（pool_dump）；反向入池断链`);
    if (entryQ.status !== 'queued') result.problems.push(`入池态异常：期望 queued，实际 ${entryQ.status}`);

    // 6 改文造 stale 锚（edit_body 走正规写入口）。
    const edit = dbg(
      GOODSHARE,
      'action',
      'edit_body',
      JSON.stringify({ titleMatch: ONDEVICE_TITLE, append: `\n\n（on-device stale 构造 ${isoNow()}）` }),
    );
    if (!edit?.result?.ok) throw new Error(`edit_body 失败：${JSON.stringify(edit).slice(0, 200)}`);
    const versionAfterEdit = edit?.result?.result?.item?.version ?? null;

    // 7 预热装载（懒加载立法：无聊天 Run 则引擎恒冷，drain 直接执行会 failFast
    // 回池——2026-11-08 首跑实证）。query_on_device 走 _ensureEngineReady
    // （enable + 轮询就绪）+ 真实 generate；**要求真出字才算热**——引擎
    // ready 态先于权重就绪，热身后首轮真任务可能 149ms 空产出（同日四跑
    // 实证），故以「产出 chars>0」为热判据重试，最多 6 轮 × 3s。
    adb('shell', 'am', 'start', '-n', `${GOODHUB}/.MainActivity`);
    await sleep(1200);
    let warmChars = -1;
    let warmErr = null;
    for (let i = 0; i < 6; i++) {
      try {
        const w = dbgEnv(GOODHUB, { DBG_HTTP_TIMEOUT: '200' }, 'action', 'query_on_device',
          JSON.stringify({ prompt: '用一句话回答：1加1等于几？', maxTokens: 48 }));
        if (w?.result?.ok && Number(w.result.chars ?? 0) > 0) {
          warmChars = Number(w.result.chars);
          break;
        }
        warmErr = JSON.stringify(w?.result ?? w).slice(0, 200);
      } catch (e) {
        warmErr = String(e.message).slice(0, 200);
      }
      await sleep(3000);
    }
    if (warmChars < 0) {
      throw new Error(`引擎预热失败（6 轮无产出）：${warmErr ?? 'unknown'}（检查 goodhub 已选端侧模型 / 装载窗口）`);
    }
    result.evidence.warmupChars = warmChars;
    // drain（§G3 同步触发宿主消费；宿主已真热，执行应秒级）。引擎仍有
    // 偶发空产出回池（retries<3 毒丸上限内），给一次重试余量。
    let drained = dbgEnv(GOODHUB, { DBG_HTTP_TIMEOUT: '180' }, 'action', 'drain_supply_pool', '{"maxTasks":3}');
    let entryD = poolEntryFor(drained?.result?.pool, taskId);
    if (entryD && !poolConsumed(entryD)) {
      await sleep(4000);
      drained = dbgEnv(GOODHUB, { DBG_HTTP_TIMEOUT: '180' }, 'action', 'drain_supply_pool', '{"maxTasks":3}');
      entryD = poolEntryFor(drained?.result?.pool, taskId);
    }
    result.evidence.poolAfterDrain = entryD;
    if (!poolConsumed(entryD)) {
      result.problems.push(`drain 后任务未消费：${JSON.stringify(entryD).slice(0, 200)}`);
    }
    // 回 goodshare 前台（resume → 即时 pollOnce）。
    adb('shell', 'am', 'start', '-n', `${GOODSHARE}/.MainActivity`);

    // 8 Pull 取回 → stale 收敛（正文已改 → 失败注记，结果不落库）。
    const conv = await waitForConverge(() => {
      const tasks = readRegistry();
      return { ok: tasks.length === 0, tasks };
    }, { poke: pokeResume });
    result.evidence.registryAfterStale = registryTaskIds(conv.tasks);
    if (!conv.ok) result.problems.push(`Pull 后登记未收敛（残留 ${JSON.stringify(conv.tasks).slice(0, 300)}）`);
    result.evidence.staleNoteVisible = uiTreeHas(GOODSHARE, '条目正文已变化');
    if (!result.evidence.staleNoteVisible) result.problems.push('stale 失败注记「条目正文已变化」未出现');

    // 9 not_found 收敛（task_inject 假 taskId → 宿主应答 not_found）。
    const inj = dbg(GOODSHARE, 'action', 'task_inject', JSON.stringify({ titleMatch: ONDEVICE_TITLE }));
    if (!inj?.result?.ok) throw new Error(`task_inject 失败：${JSON.stringify(inj).slice(0, 200)}`);
    result.evidence.injectedTaskId = inj.result.taskId;
    pokeResume();
    const conv2 = await waitForConverge(() => {
      const tasks = readRegistry();
      return { ok: tasks.length === 0, tasks };
    }, { poke: pokeResume });
    result.evidence.registryAfterNotFound = registryTaskIds(conv2.tasks);
    if (!conv2.ok) result.problems.push(`not_found 后登记未收敛（残留 ${JSON.stringify(conv2.tasks).slice(0, 300)}）`);
    result.evidence.notFoundNoteVisible = uiTreeHas(GOODSHARE, '任务不存在');
    if (!result.evidence.notFoundNoteVisible) result.problems.push('not_found 失败注记「任务不存在」未出现');

    // 10 不落库断言：stale 结果不回写（summary/version 不变，正文含 stale 锚）。
    const after = await tool('get_item', { id: added.id });
    result.evidence.versionAfter = after.version;
    result.evidence.summaryUnchanged = (after.summary ?? null) === summaryBefore;
    result.evidence.textHasStaleAnchor = String(after.text ?? '').includes('on-device stale 构造');
    if (!result.evidence.summaryUnchanged) result.problems.push('summary 被回写（stale 应不落库）');
    if (!result.evidence.textHasStaleAnchor) result.problems.push('edit_body 正文锚缺失（写入口未生效）');
    if (versionAfterEdit != null && after.version !== versionAfterEdit) {
      result.problems.push(`version 漂移（edit 后 ${versionAfterEdit} → 终 ${after.version}，疑似结果回写）`);
    }
    if (!result.problems.length) result.status = 'PASS';
  } catch (e) {
    result.problems.push(`用例异常：${e.message}`);
  } finally {
    result.triggers = triggerCount - beforeTriggers;
    result.durationMs = Date.now() - started;
    // 清场：开关还原 + 登记表/任务池清场 + 删条目（host_sim 已复位无需再动）。
    const steps = [];
    const step = (name, fn) => {
      try {
        fn();
        steps.push(`${name}:ok`);
      } catch (e) {
        steps.push(`${name}:FAIL:${String(e.message).slice(0, 80)}`);
      }
    };
    step('caps-off', () => dbg(GOODSHARE, 'action', 'set_caps', '{"onDeviceAsync":false}'));
    step('registry', () => dbg(GOODSHARE, 'action', 'task_clear'));
    step('pool', () => dbg(GOODHUB, 'action', 'purge_supply_pool'));
    if (created && !keep) {
      try {
        await tool('delete_item', { id: result.itemId });
        steps.push('item:ok');
      } catch (e) {
        steps.push(`item:FAIL:${String(e.message).slice(0, 80)}`);
      }
    } else if (created) {
      steps.push('item:skipped(--keep)');
    }
    result.cleanup = steps.join(' ');
    if (result.status !== 'PASS') result.evidence.failure = collectFailureEvidence(caseId);
  }
  return result;
}

// ───────────────────────── 预检 ─────────────────────────

function resolveDevice() {
  if (device) return;
  const lines = run('adb', ['devices']).split('\n').filter((l) => /\tdevice\s*$/.test(l));
  if (lines.length === 0) throw new Error('无在线 adb 设备：adb devices 检查连接与授权');
  device = lines[0].split('\t')[0].trim();
}

function assertDebugBuilds() {
  const packages = run('adb', ['-s', device, 'shell', 'pm', 'list', 'packages']);
  for (const p of [GOODSHARE, GOODHUB]) {
    if (!packages.includes(`package:${p}`)) throw new Error(`设备未安装 ${p}；先 toolbox run build-apk --install`);
  }
  for (const p of [GOODSHARE, GOODHUB]) {
    const dump = run('adb', ['-s', device, 'shell', 'dumpsys', 'package', p]);
    if (!dump.includes('DEBUGGABLE')) {
      throw new Error(`${p} 不是 debug 包（调试桥/Deep Link 仅 debug 可用）；改装 debug APK`);
    }
  }
}

function discoverGoodshareBridge() {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const d = dbg(GOODSHARE, 'discover');
      if (d?.ok && d.token) {
        // 冷启动后 UI 可能尚未挂载，等动作面可用再继续（否则 navigate/tap 会失败）。
        for (let i = 0; i < 6; i++) {
          const ping = dbg(GOODSHARE, 'ping');
          if (ping?.result?.contextReady === true) return d;
          sleepSyncMs(1500);
        }
      }
    } catch {
      // 落到下面的冷启动自愈。
    }
    if (attempt < 2) {
      // token 只经 logcat、每次启动轮换；环形缓冲把启动行冲掉后，唯一可靠的
      // 恢复是真正冷启动——App 已在前台时 am start 不会重跑 main()，不会产出新行。
      adb('shell', 'am', 'force-stop', GOODSHARE);
      sleepSyncMs(800);
      adb('shell', 'am', 'start', '-n', `${GOODSHARE}/.MainActivity`);
      sleepSyncMs(5000);
    }
  }
  throw new Error('发现不到 goodshare 调试桥（按包名取 port/token 失败）；冷启动后仍无 [debug-bridge] 行，检查 debug 包与装配');
}

/** 同步等待：仅用于 adb 子进程之间的短间隔（execFileSync 场景下）。 */
function sleepSyncMs(ms) {
  run('sleep', [(ms / 1000).toFixed(2)]);
}

/** 复位页面栈并跳到 MCP 页：避免多次运行叠加同名路由、锚点命中旧页面。 */
function resetToMcpPage() {
  for (let i = 0; i < 8; i++) {
    const back = dbg(GOODSHARE, 'action', 'back');
    if (!back?.result?.popped) break;
  }
  const nav = dbg(GOODSHARE, 'navigate', 'mcp');
  if (!nav?.result?.ok) throw new Error(`导航到 MCP 页失败：${JSON.stringify(nav).slice(0, 300)}`);
  sleepSyncMs(1200);
}

function ensureMcpService() {
  const state = dbg(GOODSHARE, 'state');
  if (state?.app?.mcpRunning === true) return true;
  try {
    adb('shell', 'pm', 'grant', GOODSHARE, 'android.permission.POST_NOTIFICATIONS');
  } catch {
    // 部分 ROM 无需授权；前台服务失败会在下面的 state 复查里显式暴露。
  }
  // 只有需要点开关时才进 MCP 页；令牌读取走 /debug/state，不依赖控件树。
  resetToMcpPage();
  const tap = dbg(GOODSHARE, 'action', 'tap_node', '{"key":"mcp-service-switch"}');
  if (!tap?.result?.ok) throw new Error(`MCP 服务开关点击失败：${JSON.stringify(tap).slice(0, 300)}`);
  sleepSyncMs(2500);
  const after = dbg(GOODSHARE, 'state');
  if (after?.app?.mcpRunning !== true) {
    throw new Error('MCP 服务仍为关闭态（/debug/state.app.mcpRunning=false）；检查通知权限与前台服务日志');
  }
  return false;
}

/** 结构化观测：从 /debug/state.app.mcpToken 取令牌，不经 UI 显隐/控件树。 */
function readMcpToken() {
  const state = dbg(GOODSHARE, 'state');
  const token = String(state?.app?.mcpToken ?? '');
  if (!/^[0-9a-f]{24}$/.test(token)) {
    throw new Error('/debug/state.app.mcpToken 缺失或格式异常（需含结构化状态快照的 debug 包）');
  }
  mcpToken = token;
}

async function precheck() {
  resolveDevice();
  assertDebugBuilds();
  const bridge = discoverGoodshareBridge();
  const alreadyRunning = ensureMcpService();
  readMcpToken();
  try {
    adb('forward', `tcp:${MCP_PORT}`, `tcp:${MCP_PORT}`);
  } catch (e) {
    throw new Error(`adb forward tcp:${MCP_PORT} 失败（PC 端口可能被占用）：${e.message}`);
  }
  const init = await rpc('initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'ai-e2e', version: '1' },
  });
  if (!init?.serverInfo) throw new Error(`MCP initialize 无 serverInfo：${JSON.stringify(init).slice(0, 300)}`);
  return { device, bridgePort: bridge.port, mcpServiceAlreadyRunning: alreadyRunning };
}

// ───────────────────────── 驱动 ─────────────────────────

/** 宿主上线 = 唯一的生产侧触发点（catch-up claim）；重复触发次数进报告。 */
async function triggerHost() {
  adb('shell', 'am', 'force-stop', GOODHUB);
  await sleep(800);
  adb('shell', 'am', 'start', '-n', `${GOODHUB}/.MainActivity`);
  triggerCount += 1;
  await sleep(4000);
}

/**
 * 造条目会顺带入队本地管线任务；若它们尚未终态就入队远程 AI 任务，宿主
 * claim 读到的 version 会在推理期间被本地回写改掉，apply 必撞 version_conflict。
 * 测试侧先等本条目本地任务 quiescent，让用例只测远程 AI 链路（生产侧竞态
 * 另记移交件，不在测试里静默吞掉）。
 */
async function waitLocalQuiescent(itemId) {
  const deadline = Date.now() + 20000;
  let snapshot = [];
  while (Date.now() < deadline) {
    const jobs = await tool('list_jobs', { limit: 50 });
    const mine = (Array.isArray(jobs?.jobs) ? jobs.jobs : []).filter((j) => j.item_id === itemId);
    snapshot = mine.map((j) => ({ action: j.action, status: j.status }));
    const active = mine.filter((j) => !['completed', 'failed', 'cancelled'].includes(j.status));
    if (active.length === 0) return { settled: true, jobs: snapshot };
    await sleep(1000);
  }
  return { settled: false, jobs: snapshot };
}

async function waitForJob(jobId) {
  const deadline = Date.now() + timeoutSec * 1000;
  const extraTriggersAt = [Date.now() + 30000, Date.now() + 70000];
  let extra = 0;
  let last = null;
  while (Date.now() < deadline) {
    last = await tool('get_job_status', { job_id: jobId });
    if (last?.found && ['completed', 'failed', 'cancelled'].includes(last.status)) {
      return { job: last, extraTriggers: extra, timedOut: false };
    }
    if (extra < extraTriggersAt.length && Date.now() >= extraTriggersAt[extra]) {
      await triggerHost();
      extra += 1;
    }
    await sleep(3000);
  }
  return { job: last, extraTriggers: extra, timedOut: true };
}

function collectFailureEvidence(caseId) {
  const paths = {};
  try {
    const log = adb('logcat', '-d')
      .split('\n')
      .filter((l) => /\[task-consume\]|\[task-loop\]|\[DEGRADE\]|debug-bridge|claim_ai_task|apply_ai_result|task-.+failed/.test(l))
      .slice(-80)
      .join('\n');
    const p = resolve(REPORT_DIR, `${caseId}-device.log`);
    writeFileSync(p, log);
    paths.deviceLog = p;
  } catch {
    // 现场采集失败不覆盖原始失败原因，只缺席证据。
  }
  try {
    const host = dbg(GOODHUB, 'logs', '--since', '0');
    const p = resolve(REPORT_DIR, `${caseId}-host-logs.json`);
    writeFileSync(p, JSON.stringify(host, null, 2));
    paths.hostLogs = p;
  } catch {
    // 宿主桥 token 随冷启动轮换，取不到时设备日志已足够定位。
  }
  try {
    const p = resolve(REPORT_DIR, `${caseId}-screen.png`);
    dbg(GOODSHARE, 'screenshot', p);
    paths.screenshot = p;
  } catch {
    // 截图是增强证据，端点未注入或页面未挂载不阻断报告。
  }
  return paths;
}

async function runCase(def, round) {
  const started = Date.now();
  const beforeTriggers = triggerCount;
  const caseId = round == null ? def.id : `${def.id}-r${round}`;
  const result = {
    id: caseId,
    caseId: def.id,
    round: round ?? 1,
    label: def.label,
    status: 'FAIL',
    itemId: null,
    jobId: null,
    triggers: 0,
    durationMs: 0,
    problems: [],
    evidence: {},
    cleanup: null,
  };
  let created = false;
  try {
    const content = `${SAMPLE_TEXT}\n\n（自动化样本 ${isoNow()}）`;
    const added = await tool('add_item', {
      content,
      title: `[AI-E2E] ${def.id}`,
      tags: def.seedTags,
    });
    if (!added?.id) throw new Error(`add_item 未返回条目 id：${JSON.stringify(added).slice(0, 300)}`);
    created = true;
    result.itemId = added.id;

    const local = await waitLocalQuiescent(added.id);
    result.evidence.localJobsAtEnqueue = local.jobs;
    if (!local.settled) result.problems.push('本条目本地任务 20s 内未到终态（version 可能继续变动）');
    const before = await tool('get_item', { id: added.id });
    const queued = await tool(def.enqueueTool, { id: added.id });
    result.jobId = queued?.job_id ?? null;
    if (!result.jobId) throw new Error(`${def.enqueueTool} 未返回 job_id：${JSON.stringify(queued).slice(0, 300)}`);

    const queuedJob = await tool('get_job_status', { job_id: result.jobId });
    if (queuedJob?.found && queuedJob.action !== def.action) {
      throw new Error(`入队动作不符：期望 ${def.action}，实际 ${queuedJob.action}`);
    }
    // 入队命令本身会写 is_processed=0 并递增 version；此快照是判断
    // 「apply 回写有没有发生」的正确基准。
    const enqueued = await tool('get_item', { id: added.id });

    await triggerHost();
    const waited = await waitForJob(result.jobId);
    const after = await tool('get_item', { id: added.id });
    Object.assign(result.evidence, {
      ...def.evidence(after, waited.job),
      jobStatus: waited.job?.status ?? null,
      jobNote: waited.job?.note ?? null,
      versionBefore: before.version,
      versionAtEnqueue: enqueued.version,
      versionAfter: after.version,
      timedOut: waited.timedOut,
      extraTriggers: waited.extraTriggers,
    });
    result.problems.push(...def.check(before, after, waited.job, enqueued));
    if (waited.timedOut) result.problems.push(`等待 ${timeoutSec}s 后任务未到终态`);
    if (!result.problems.length) result.status = 'PASS';
  } catch (e) {
    result.problems.push(`用例异常：${e.message}`);
  } finally {
    result.triggers = triggerCount - beforeTriggers;
    result.durationMs = Date.now() - started;
    if (created) {
      if (keep) {
        result.cleanup = 'skipped(--keep)';
      } else {
        try {
          const deleted = await tool('delete_item', { id: result.itemId });
          result.cleanup = deleted?.ok ? 'ok' : `unexpected:${JSON.stringify(deleted).slice(0, 200)}`;
        } catch (e) {
          result.cleanup = `FAIL:${e.message}`;
        }
      }
    }
    if (result.status !== 'PASS') result.evidence.failure = collectFailureEvidence(caseId);
  }
  return result;
}

// ───────────────────────── 自测 / 入口 ─────────────────────────

function selfTest() {
  const before = { text: SAMPLE_TEXT, tags: ['e2e-基线'], version: 1 };
  const okJob = (action) => ({ found: true, status: 'completed', action });
  const goodSummary = { ...before, summary: '这是由宿主模型生成的摘要文本，内容与原文不同但语义一致。', summary_stale: false, version: 2 };
  const goodTags = { ...before, tags: ['e2e-基线', '分享收集器', 'MCP'], version: 2 };
  const checks = [
    ['summary 好样本通过', checkSummary(before, goodSummary, okJob('llm_summarize')).length === 0],
    ['summary 抓空产出', checkSummary(before, { ...before, version: 2 }, okJob('llm_summarize')).length > 0],
    ['summary 抓失败终态', checkSummary(before, goodSummary, { ...okJob('llm_summarize'), status: 'failed', note: '引擎不可用' }).length > 0],
    ['summary 抓原文覆盖', checkSummary(before, { ...goodSummary, text: '被改坏' }, okJob('llm_summarize')).length > 0],
    ['summary 抓占位回写', checkSummary(before, { ...before, summary: SAMPLE_TEXT, version: 2 }, okJob('llm_summarize')).length > 0],
    ['tags 好样本通过', checkTags(before, goodTags, okJob('llm_tags')).length === 0],
    ['tags 抓无新增', checkTags(before, { ...before, version: 2 }, okJob('llm_tags')).length > 0],
    ['tags 抓原标签被删', checkTags(before, { ...before, tags: ['别的标签'], version: 2 }, okJob('llm_tags')).length > 0],
    ['tags 抓整段文本切碎', checkTags(before, { ...before, tags: ['e2e-基线', '**核心架构与能力**', '*   **来源渠道**：微信', '拾贝 Android 应用处理结果摘要：'], version: 2 }, okJob('llm_tags')).length > 0],
    ['tags 抓超长标签', checkTags(before, { ...before, tags: ['e2e-基线', '这是一段远远超过二十四字符上限的长句子当作标签使用'], version: 2 }, okJob('llm_tags')).length > 0],
    ['tags 护栏生效（failed + note + 数据干净）判 PASS', checkTags(before, before, { ...okJob('llm_tags'), status: 'failed', note: '回写被拒：AI 产出标签形态不合规：…（schema_invalid）' }).length === 0],
    ['tags 抓随便 failed 无原因', checkTags(before, before, { ...okJob('llm_tags'), status: 'failed', note: '处理异常：超时' }).length > 0],
    ['tags 抓护栏触发但数据仍被污染', checkTags(before, { ...before, tags: ['e2e-基线', '**碎片**'], version: 2 }, { ...okJob('llm_tags'), status: 'failed', note: '回写被拒：AI 产出标签形态不合规：…' }).length > 0],
    ['on-device 登记表 id 提取', JSON.stringify(registryTaskIds([{ taskId: 't1' }, { taskId: 't2' }])) === '["t1","t2"]'],
    ['on-device 空登记表容错', JSON.stringify(registryTaskIds(null)) === '[]'],
    ['on-device 池条目命中', poolEntryFor([{ taskId: 'a' }, { taskId: 'b' }], 'b')?.taskId === 'b'],
    ['on-device 池条目未命中为 null', poolEntryFor([{ taskId: 'a' }], 'x') === null],
    ['on-device 已消费态判读', ['pendingDelivery', 'delivered'].every((s) => poolConsumed({ taskId: 'a', status: s }))],
    ['on-device 在途态不判已消费', !poolConsumed({ taskId: 'a', status: 'queued' }) && !poolConsumed(null)],
    ['on-device 残留登记被抓', registryResidueProblems([{ taskId: 't' }]).length > 0 && registryResidueProblems([]).length === 0],
  ];
  let failed = 0;
  for (const [name, ok] of checks) {
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}`);
    if (!ok) failed++;
  }
  console.log(`self-test: ${checks.length - failed}/${checks.length} 通过（含坏样本必须被抓）`);
  process.exit(failed ? 1 : 0);
}

async function main() {
  if (selfTestOnly) return selfTest();
  mkdirSync(REPORT_DIR, { recursive: true });
  let env = {};
  try {
    env = await precheck();
    console.log(`[precheck] OK  设备=${device} goodshare桥=${env.bridgePort} MCP=127.0.0.1:${MCP_PORT}`);
  } catch (e) {
    console.error(`[precheck] FAIL  ${e.message}`);
    console.error('[remedy] 确认双 debug 包已装、goodshare MainActivity 已启动、logcat 未被清空');
    process.exit(1);
  }
  if (precheckOnly) {
    console.log('[precheck] 完成（--precheck 不跑用例）');
    return;
  }

  const isOnDevice = caseFilter === 'ondevice';
  const selected = caseFilter === 'all' ? CASES : CASES.filter((c) => c.id === caseFilter);
  if (!isOnDevice && selected.length === 0) {
    console.error(`[case] 未知用例 ${caseFilter}（可用：all / summary / tags / ondevice）`);
    process.exit(2);
  }

  const results = [];
  if (isOnDevice) {
    for (let round = 1; round <= repeat; round++) {
      const r = await runOnDeviceCase('ondevice');
      results.push(r);
      const tag = repeat > 1 ? ` [${round}/${repeat}]` : '';
      console.log(`${r.status}  ${r.label}${tag}  ${r.durationMs}ms  触发=${r.triggers}  task=${r.jobId ?? '-'}`);
      for (const p of r.problems) console.log(`      - ${p}`);
      if (r.cleanup) console.log(`      - 清场: ${r.cleanup}`);
    }
  } else {
    for (const def of selected) {
      for (let round = 1; round <= repeat; round++) {
        const r = await runCase(def, repeat > 1 ? round : null);
        results.push(r);
        const tag = repeat > 1 ? ` [${round}/${repeat}]` : '';
        const guard = r.evidence.guardTriggered ? ' [护栏生效]' : '';
        console.log(`${r.status}  ${r.label}${tag}${guard}  ${r.durationMs}ms  触发=${r.triggers}  job=${r.jobId ?? '-'}`);
        for (const p of r.problems) console.log(`      - ${p}`);
        if (r.cleanup?.startsWith('FAIL')) console.log(`      - 清场失败：${r.cleanup}`);
      }
    }
  }

  const failed = results.filter((r) => r.status !== 'PASS').length;
  const byCase = {};
  for (const r of results) {
    const b = (byCase[r.caseId] ??= { rounds: 0, passed: 0, failed: 0 });
    b.rounds += 1;
    if (r.status === 'PASS') b.passed += 1;
    else b.failed += 1;
  }
  const report = {
    at: isoNow(),
    device,
    environment: {
      goodshare: GOODSHARE,
      goodhub: GOODHUB,
      goodshareBridgePort: env.bridgePort ?? null,
      mcpEndpoint: MCP_URL,
      timeoutSec,
      keep,
    },
    summary: { total: results.length, passed: results.length - failed, failed },
    repeat,
    byCase,
    cases: results,
  };
  writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`[report] ${reportPath}  ${report.summary.passed}/${report.summary.total} PASS`);
  for (const [id, stat] of Object.entries(byCase)) {
    console.log(`[byCase] ${id}: ${stat.passed}/${stat.rounds} PASS`);
  }
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error(`FAIL(自身故障)：${e.stack || e.message}`);
  process.exit(2);
});
