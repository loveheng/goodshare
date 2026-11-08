#!/usr/bin/env bash
# toolbox-script
# format: v1
# name: ai-e2e
# summary: 真机 AI 能力自动化验收（摘要/分类）：预检→造条目→宿主上线→语义等待→断言回写→清场→报告
# trigger: manual
# platform: unix
# cat: test
# alias: aie2e
# self-test: --self-test
# 备注: 薄管道——用例编排/断言/报告本体在 scripts/e2e/ai-capability-e2e.mjs，
#       本壳只做环境注入与参数透传，不复制业务胶水。

set -u
export PATH="$HOME/android-sdk/platform-tools:$HOME/flutter/bin:$PATH"
export ANDROID_HOME="$HOME/android-sdk"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENTRY="$ROOT/scripts/e2e/ai-capability-e2e.mjs"

usage() {
  cat <<'EOF'
ai-e2e — 真机 AI 能力自动化验收（试点：摘要 / 分类）

用法:
  toolbox run ai-e2e --device <SERIAL> [--case all|summary|tags|ondevice] [选项]
  toolbox run ai-e2e --device <SERIAL> --precheck     # 只跑链路预检，不造数据
  toolbox run ai-e2e --device <SERIAL> --self-test                      # 断言金丝雀（不连设备）
  toolbox run ai-e2e --json                           # 环境预检结论，不跑用例

选项（原样透传本体）:
  --case <id>        all（默认）/ summary / tags / ondevice（W6-a 端侧链路：冷宿主
                     queued→占位→drain→stale/not_found 收敛，全结构化断言）
  --timeout <秒>     单用例等待任务终态的超时（默认 120）
  --repeat <N>       每个能力重复采样 N 次（默认 1）——AI 产出具不确定性，
                     重复采样才能暴露偶发退化，报告按能力聚合 PASS 率
  --keep             保留测试条目不清场（排查用）
  --report <path>    报告路径（默认 build/e2e/ai-capability-report.json）

前置: 双 App 均装 debug 包且同机签名一致；goodshare 的 MCP 服务开关由预检自动打开；
      goodhub 的 AI 引擎（BYOK 或端侧模型）须就绪，否则任务会带 note 失败并被判 FAIL。
输出: 逐用例 PASS/FAIL + 报告 JSON（失败附设备日志/宿主日志/截图路径）；不含任何令牌。
EOF
}

json_ok() { printf '{"status":"OK","severity":"info","message":"%s"}\n' "$1"; exit 0; }
json_fail() {
  printf '{"status":"FAIL","severity":"error","message":"%s","remedy":"%s"}\n' "$1" "$2"
  exit 1
}

MODE=run
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --json) MODE=json; shift ;;
    --self-test) MODE=selftest; shift ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

precheck() {
  command -v adb >/dev/null 2>&1 || return 1
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$ENTRY" ] || return 1
  local serial=""
  local i=0
  while [ $i -lt ${#ARGS[@]} ]; do
    if [ "${ARGS[$i]}" = "--device" ]; then serial="${ARGS[$((i+1))]:-}"; break; fi
    i=$((i+1))
  done
  if [ -n "$serial" ]; then
    adb -s "$serial" get-state >/dev/null 2>&1 || return 2
  else
    adb devices 2>/dev/null | tr -d '\r' | grep -qE '^[^[:space:]]+[[:space:]]+device$' || return 2
  fi
  return 0
}

case "$MODE" in
  json)
    precheck && json_ok "ai-e2e 环境就绪（adb/node/本体/设备）"
    rc=$?
    if [ "$rc" = 2 ]; then
      json_fail "设备不在线或串号错误" "adb devices 查串号后传 --device <SERIAL>"
    fi
    json_fail "adb / node / 本体缺失" "export PATH=\$HOME/android-sdk/platform-tools:\$PATH；确认 scripts/e2e/ai-capability-e2e.mjs 存在"
    ;;
  selftest) exec node "$ENTRY" --self-test ;;
  run) exec node "$ENTRY" "${ARGS[@]}" ;;
esac
