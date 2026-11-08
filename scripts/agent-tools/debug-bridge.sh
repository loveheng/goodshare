#!/usr/bin/env bash
# toolbox-script
# format: v1
# name: debug-bridge
# summary: AI 真机调试桥 CLI（adb forward + token 提取 + /debug/* 端点透传）
# trigger: manual
# platform: unix
# alias: dbg
# cat: test
# self-test: --self-test

set -u

# 设备级/聚合层命令只在 goodhub 仓统一入口实现；本仓副本对转发白名单命令
# 转发，原有命令与参数保持不动（禁复制实现造成双副本分叉，设计稿 §11）。
# 白名单 = capture（聚合联采，§G5）+ freeze-check/unfreeze（设备级 freezer，
# §G4）；微观命令（state/logs/ui-tree/action…）本仓本地执行。
for _dbg_arg in "$@"; do
  case "$_dbg_arg" in
    capture|freeze-check|unfreeze) ;;
    *) continue ;;
  esac
  _dbg_entry="$(cd "$(dirname "$(readlink -f "$0")")/../../../goodhub/scripts/agent-tools" 2>/dev/null && pwd)/debug-bridge.sh"
  [ -f "$_dbg_entry" ] || {
    echo "[remedy] 需同级 goodhub 仓的 scripts/agent-tools/debug-bridge.sh" >&2
    echo "FAIL: 统一入口不存在: $_dbg_entry" >&2
    exit 1
  }
  export DEBUG_BRIDGE_APP_PACKAGE="${DEBUG_BRIDGE_APP_PACKAGE:-com.zzh.goodshare}"
  _dbg_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --package)
        [ $# -ge 2 ] || { echo "FAIL: --package 缺包名" >&2; exit 2; }
        export DEBUG_BRIDGE_APP_PACKAGE="$2"; shift 2 ;;
      *) _dbg_args+=("$1"); shift ;;
    esac
  done
  exec bash "$_dbg_entry" "${_dbg_args[@]}"
done

PORT=""                 # 空 = 从 logcat 按包名发现实际端口；--port 显式覆盖
DEVICE=""
CMD=""
NAME=""
PAGE=""
JSON_ARGS='{}'
SINCE=0
MODE=run
SHOT_PATH=""
BRIDGE_PORT=""
BRIDGE_TOKEN=""
URL=""
BODY=""

# 宿主 app 包名（前台守卫 / soft-hint 判定 / 调试桥发现用）。默认 goodshare；
# 跨项目分发时各仓副本用 DEBUG_BRIDGE_APP_PACKAGE 覆盖；单设备多 App 联调时
# 用 --package 逐次指定（设备 loopback 为整机共享，各 App 桥端口必须互异）。
APP_PACKAGE="${DEBUG_BRIDGE_APP_PACKAGE:-com.zzh.goodshare}"

usage() {
  cat <<'EOF'
debug-bridge — AI 真机调试桥 CLI（薄管道：只做 adb forward + token 提取 + HTTP 透传）

用法:
  debug-bridge.sh --device <SERIAL> <command> [args]
  debug-bridge.sh --json                      # 预检结论，不执行任务本体
  debug-bridge.sh --self-test                 # 参数校验金丝雀

命令:
  state                       GET  /debug/state
  logs [--since N]            GET  /debug/logs?since=N
  ui-tree                     GET  /debug/ui-tree
  action <name> [JSON_ARGS]   POST /debug/action  {"action":name,"args":JSON_ARGS}
  navigate <page>             action navigate {"page":page}
  ping                        action ping（检查 UI 执行面是否挂载）
  tap_bounds <x,y[,w,h]>      逻辑坐标点击（ui-tree bounds 直接粘贴；桥内换算
                              设备像素，含前台守卫——防误触其他 app）
  tap_text <子串>             语义点击：ui-tree 按文本找首个匹配节点，自动算
                              中心点击（免坐标换算；含前台守卫）
  wait_log <ERE> [timeout_s]  阻塞等 logcat 出现匹配行（默认 60s，2s 步进；
                              语义等待替代 sleep 盲等）
  device-log [ERE] [N]        一次性拉 logcat 最近 N 行（默认 200）文本过滤
                              （-a 纯文本模式，规避二进制行 grep 失效）
  foreground                  报告当前前台包名 + 是否宿主 app——消除「我在
                              哪个 app」盲区（SAF/系统弹窗时判断用桥面还是
                              系统级驱动）
  system-ui [text_substr]     系统 UI 可点节点结构化导出（uiautomator dump +
                              ElementTree 解析：text/desc/clickable/bounds
                              中心点；可选 text 子串过滤）——SAF 选择器/权限
                              弹窗等 Flutter 树外的系统 UI 驱动入口
  system-tap <x,y>            系统级 tap（设备像素直接 tap，豁免宿主前台
                              守卫——就是要点系统层；软提示当前前台防误触）
  discover                    按包名发现该 App 调试桥的 {package,port,token}
                              （单设备多 App 联调：logcat 按 pid 过滤，token 不串台）
  screenshot [out.png]        GET /debug/screenshot → 解码 base64 存 PNG

全局选项:
  --device <SERIAL>           adb 串号（必填）
  --package <包名>             目标 App（默认 DEBUG_BRIDGE_APP_PACKAGE 或 com.zzh.goodshare）
  --port <N>                  显式指定设备桥端口（跳过端口发现）

示例:
  toolbox run debug-bridge --device <SERIAL> ui-tree
  toolbox run debug-bridge --device <SERIAL> --package com.zzh.goodhub discover
  toolbox run debug-bridge --device <SERIAL> action tap_node '{"key":"composer-attach"}'
  toolbox run debug-bridge --device <SERIAL> navigate logs

前置: 真机装 debug 包并启动（toolbox run build-apk --install）；token/port 由 logcat 现取。
输出: 端点原始 JSON（不做业务解析，交给调用方）。--json 只回一行契约结论。
EOF
}

json_ok() { printf '{"status":"OK","severity":"info","message":"%s"}\n' "$1"; exit 0; }
json_fail() {
  printf '{"status":"FAIL","severity":"error","message":"%s","remedy":"%s"}\n' "$1" "$2"
  exit 1
}
fail() {
  echo "[remedy] $2" >&2
  echo "FAIL: $1" >&2
  exit 1
}

valid_name() { printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]*$'; }
valid_page() { printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]*$'; }

self_test() {
  valid_name tap_node || { echo "self-test: 好动作名被拒"; return 2; }
  ! valid_name 'tap;rm -rf /' || { echo "self-test: 坏动作名未拦住"; return 2; }
  valid_page logs || { echo "self-test: 好页面名被拒"; return 2; }
  ! valid_page 'logs/../x' || { echo "self-test: 坏页面名未拦住"; return 2; }
  echo "self-test: OK（好/坏样本各 2 例）"
  return 0
}

precheck() {
  command -v adb >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  adb -s "$DEVICE" get-state >/dev/null 2>&1 || return 1
  return 0
}

# 按包名发现该 App 的调试桥端口与 token（多实例共存的核心）。
# logcat 默认列：日期 时间 pid tid 级别 tag : 消息；pidof 给出目标包全部 pid，
# 用第 3/4 列过滤，避免同机多 App 的 token 串台。只认含 token= 的启动行，
# [DEGRADE] 启动失败行不带 token，天然排除。
#
# 凭据缓存回退（联调设施 §G1 强化）：logcat token 启动行会被环形缓冲冲掉
# （高频日志实测 <10min），App 未重启时 pid 不变 → 缓存凭据可用。校验双闸 =
# 当前 pid ∈ 缓存 pid 集（防串台）+ HTTP ping 2s 通（防失活）；失配即弃。
# capture 的 bridge.json 同思路（§G5 先例），此处覆盖 CLI 全命令面。
creds_dir() { printf '%s' "${DEBUG_BRIDGE_CREDS_DIR:-/tmp/.debug-bridge-creds}"; }

creds_put() { # $1 = pids（空格分隔）
  local d; d="$(creds_dir)"; mkdir -p "$d" 2>/dev/null || return 0
  printf '%s' "$BRIDGE_TOKEN" > "$d/$DEVICE-$APP_PACKAGE.token" 2>/dev/null || return 0
  printf '%s' "$BRIDGE_PORT" > "$d/$DEVICE-$APP_PACKAGE.port" 2>/dev/null || return 0
  printf '%s\n' "$1" > "$d/$DEVICE-$APP_PACKAGE.pids" 2>/dev/null || return 0
  chmod 600 "$d/$DEVICE-$APP_PACKAGE.token" \
    "$d/$DEVICE-$APP_PACKAGE.port" "$d/$DEVICE-$APP_PACKAGE.pids" 2>/dev/null || true
}

creds_get() { # 依赖全局 pids_g（discover_bridge 置位）
  local d; d="$(creds_dir)"
  local pf="$d/$DEVICE-$APP_PACKAGE.pids"
  [ -f "$pf" ] || return 1
  local cpids cur ok=""
  cpids="$(tr -d '\r' < "$pf" 2>/dev/null)"
  for cur in $pids_g; do
    case " $cpids " in *" $cur "*) ok=1 ;; esac
  done
  [ -n "$ok" ] || return 1
  BRIDGE_TOKEN="$(cat "$d/$DEVICE-$APP_PACKAGE.token" 2>/dev/null)"
  BRIDGE_PORT="$(cat "$d/$DEVICE-$APP_PACKAGE.port" 2>/dev/null)"
  [ -n "$BRIDGE_TOKEN" ] && [ -n "$BRIDGE_PORT" ] || return 1
  adb -s "$DEVICE" forward "tcp:$BRIDGE_PORT" "tcp:$BRIDGE_PORT" >/dev/null 2>&1 || return 1
  curl -sS --max-time 3 -H "Authorization: Bearer $BRIDGE_TOKEN" \
    "http://127.0.0.1:$BRIDGE_PORT/debug/state" >/dev/null 2>&1 || return 1
  return 0
}

discover_bridge() {
  local pids line
  pids="$(adb -s "$DEVICE" shell pidof "$APP_PACKAGE" 2>/dev/null \
    | tr -d '\r' | tr '\n' ' ')"
  [ -n "${pids// /}" ] || return 1
  pids_g="$pids"
  line="$(adb -s "$DEVICE" logcat -d 2>/dev/null \
    | grep -aF 'token=' \
    | grep -aF '[debug-bridge]' \
    | awk -v p="$pids" '
        BEGIN { n=split(p, a, /[ \t]+/); for (i=1;i<=n;i++) if (a[i] != "") ok[a[i]]=1 }
        ($3 in ok) || ($4 in ok) { last=$0 }
        END { print last }')"
  if [ -n "$line" ]; then
    BRIDGE_TOKEN="$(printf '%s' "$line" | grep -oE 'token=[^ ]+' | tail -1 \
      | cut -d= -f2 | tr -d '\r[:space:]')"
    if [ -n "$BRIDGE_TOKEN" ]; then
      if [ -z "$BRIDGE_PORT" ]; then
        BRIDGE_PORT="$(printf '%s' "$line" | grep -oE '127\.0\.0\.1:[0-9]+' \
          | tail -1 | cut -d: -f2)"
      fi
      if [ -n "$BRIDGE_PORT" ]; then
        creds_put "$pids"
        return 0
      fi
    fi
  fi
  # DEGRADE 回退：token 行被冲 ≠ 桥死了——凭据缓存双闸校验后复用。
  creds_get
}

# 提取当前前台 app 包名（dumpsys topResumedActivity 的 `u0 <pkg>/` 段）。
# 通用提取（不限定宿主包名），配合 [APP_PACKAGE] 做精确匹配——跨项目分发后
# 守卫/soft-hint 仍按各自包名判定，不再依赖 goodhub 硬编码。
foreground_pkg() {
  adb -s "$DEVICE" shell dumpsys activity activities 2>/dev/null \
    | grep -E 'topResumedActivity|ResumedActivity' | tail -1 \
    | grep -oE 'u0 [a-zA-Z0-9_.]+/' | head -1 \
    | awk '{print $2}' | sed 's|/$||'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --self-test) self_test; exit $? ;;
    --json) MODE=json; shift ;;
    --device) DEVICE="${2:-}"; shift 2 ;;
    --package) APP_PACKAGE="${2:-}"; shift 2 ;;
    --port)
      PORT="${2:-}"; shift 2
      case "$PORT" in ''|*[!0-9]*) fail "非法 port: $PORT" "--port <1-65535>" ;; esac
      ;;
    discover) CMD=discover; shift ;;
    screenshot)
      CMD=screenshot; shift
      SHOT_PATH="${1:-}"; [ $# -gt 0 ] && shift
      ;;
    state|ui-tree|ping) CMD="$1"; shift ;;
    logs)
      CMD=logs
      shift
      if [ "${1:-}" = "--since" ]; then SINCE="${2:-0}"; shift 2; fi
      case "$SINCE" in
        *[!0-9]*) fail "since 必须是非负整数: $SINCE" "logs --since 0" ;;
      esac
      ;;
    --file)
      ARGS_FILE="${2:-}"; shift 2
      [ -n "$ARGS_FILE" ] && [ -f "$ARGS_FILE" ] || fail "--file 缺文件: $ARGS_FILE" "先写 JSON 到文件再 --file 传入"
      JSON_ARGS="$(cat "$ARGS_FILE")"
      ;;
    tap_bounds)
      CMD=tap_bounds; BOUNDS="${2:-}"; shift 2
      printf '%s' "$BOUNDS" | grep -Eq '^[0-9.]+,[0-9.]+(,[0-9.]+,[0-9.]+)?$'         || fail "非法 bounds: $BOUNDS" "格式 x,y 或 x,y,w,h（ui-tree bounds 逻辑像素，直接粘贴）"
      ;;
    tap_text)
      CMD=tap_text; TAP_PAT="${2:-}"; shift 2
      [ -n "$TAP_PAT" ] || fail "缺子串" "tap_text <子串>（ui-tree 文本匹配，首个命中节点）"
      ;;
    wait_log)
      CMD=wait_log; WAIT_PAT="${2:-}"; shift 2
      WAIT_TMO="${1:-60}"; [ $# -gt 0 ] && shift
      case "$WAIT_TMO" in *[!0-9]*) fail "timeout 必须是秒数: $WAIT_TMO" "wait_log <ERE> [timeout_s]" ;; esac
      ;;
    device-log)
      CMD=device_log; shift
      DL_PAT="${1:-}"; [ $# -gt 0 ] && shift
      DL_TAIL="${1:-200}"; [ $# -gt 0 ] && shift
      case "$DL_TAIL" in *[!0-9]*) fail "tail 必须是行数: $DL_TAIL" "device-log [ERE] [N]" ;; esac
      ;;
    foreground)
      CMD=foreground; shift ;;
    system-ui)
      CMD=system_ui; shift; SU_SUB="${1:-}"; [ $# -gt 0 ] && shift ;;
    system-tap)
      CMD=system_tap; ST_X="${2:-}"; ST_Y="${3:-}"
      [ $# -ge 3 ] && shift 3   # 消耗 command + x + y（残留会被 while 循环再迭代误判 unknown）
      case "$ST_X,$ST_Y" in
        *[!0-9,]*) fail "非法坐标: $ST_X,$ST_Y" "格式 x,y（设备像素，system-ui 中心点直接粘贴）" ;;
      esac
      ;;
    navigate)
      CMD=navigate
      PAGE="${2:-}"
      shift 2
      valid_page "$PAGE" || fail "非法 page: $PAGE" "仅小写字母/数字/连字符，如 logs gateway settings"
      JSON_ARGS="{\"page\":\"$PAGE\"}"
      ;;
    action)
      CMD=action
      NAME="${2:-}"
      shift 2
      valid_name "$NAME" || fail "非法 action: $NAME" "动作名须匹配 ^[a-z_][a-z0-9_-]*"
      if [ $# -gt 0 ]; then JSON_ARGS="$1"; shift
      elif [ ! -t 0 ]; then STDIN_ARGS="$(cat)";
        [ -n "$STDIN_ARGS" ] && JSON_ARGS="$STDIN_ARGS"; fi
      ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$MODE" = "json" ]; then
  if [ -n "$DEVICE" ]; then
    precheck && json_ok "debug-bridge 预检通过（adb/curl/设备就绪）"
    json_fail "adb 或 curl 不可用，或设备不在线" "adb devices 查串号；export PATH=\$HOME/android-sdk/platform-tools:\$PATH"
  fi
  if command -v adb >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    json_ok "debug-bridge 可用（裸跑需 --device <SERIAL>）"
  fi
  json_fail "adb 或 curl 不在 PATH" "export PATH=\$HOME/android-sdk/platform-tools:\$PATH"
fi

[ -n "$CMD" ] || { usage; exit 2; }
[ -n "$DEVICE" ] || fail "缺 --device" "adb devices 查串号后传 --device <SERIAL>"
precheck || fail "adb/curl 不可用或设备不在线" "adb devices；export PATH=\$HOME/android-sdk/platform-tools:\$PATH"

# 纯设备侧命令不得被桥 token 缺失挡住（logcat 被清、桥未启动时仍可用）。
case "$CMD" in
  device_log|wait_log|foreground|system_ui|system_tap) NEED_BRIDGE=0 ;;
  *) NEED_BRIDGE=1 ;;
esac

if [ "$NEED_BRIDGE" = 1 ]; then
  [ -n "$PORT" ] && BRIDGE_PORT="$PORT"
  discover_bridge || fail "按包名 $APP_PACKAGE 发现不到调试桥（端口/token）" \
    "确认装 debug 包且 App 已启动；logcat 被清则重启 App 重新产出 [debug-bridge] 行"
  PORT="$BRIDGE_PORT"
  TOKEN="$BRIDGE_TOKEN"
  if [ "$CMD" != discover ]; then
    adb -s "$DEVICE" forward "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1 \
      || fail "adb forward tcp:$PORT 失败" "检查端口占用与设备连接"
  fi
  BASE="http://127.0.0.1:$PORT"
  AUTH="Authorization: Bearer $TOKEN"
  CONTENT="Content-Type: application/json"
fi

case "$CMD" in
  state) URL="$BASE/debug/state"; BODY="" ;;
  logs) URL="$BASE/debug/logs?since=$SINCE"; BODY="" ;;
  ui-tree) URL="$BASE/debug/ui-tree"; BODY="" ;;
  ping) URL="$BASE/debug/action"; BODY='{"action":"ping","args":{}}' ;;
  navigate) URL="$BASE/debug/action"; BODY="{\"action\":\"navigate\",\"args\":$JSON_ARGS}" ;;
  action) URL="$BASE/debug/action"; BODY="{\"action\":\"$NAME\",\"args\":$JSON_ARGS}" ;;
  discover|screenshot) ;;   # 桥面独立命令，不走 URL/BODY 透传
esac

# —— 桥面独立命令（不透传 HTTP）——
assert_foreground() {
  local fg
  fg="$(foreground_pkg)"
  case "$fg" in
    "$APP_PACKAGE"*) return 0 ;;
    *)
      fail "前台不是宿主 app（当前: ${fg:-unknown}，期望: $APP_PACKAGE）" \
        "am start -n $APP_PACKAGE/.MainActivity 拉起后重试——前台守卫防误触其他 app（2026-11-05 微信误点事故）"
      ;;
  esac
}

case "$CMD" in
  discover)
    printf '{"ok":true,"package":"%s","port":%s,"token":"%s"}\n' \
      "$APP_PACKAGE" "$PORT" "$TOKEN"
    exit 0
    ;;
  screenshot)
    [ -n "$SHOT_PATH" ] || SHOT_PATH="debug-bridge-$(date +%Y%m%d-%H%M%S).png"
    SHOT_JSON="$(curl -sS --max-time 20 -H "$AUTH" "$BASE/debug/screenshot" 2>&1)" \
      || fail "screenshot 端点请求失败" "$SHOT_JSON"
    printf '%s' "$SHOT_JSON" | python3 -c '
import sys, json, base64, pathlib
d = json.load(sys.stdin)
if not d.get("ok"):
    print(json.dumps(d, ensure_ascii=False)); sys.exit(1)
pathlib.Path(sys.argv[1]).write_bytes(base64.b64decode(d["data"]))
print(json.dumps({"ok": True, "bytes": d.get("bytes"), "path": sys.argv[1]}, ensure_ascii=False))
' "$SHOT_PATH" || fail "screenshot 解码失败" "$SHOT_JSON"
    exit 0
    ;;
  tap_text)
    assert_foreground
    TREE="$(curl -sS --max-time 10 -H "$AUTH" "$BASE/debug/ui-tree" 2>&1)" \
      || fail "ui-tree 请求失败" "$TREE"
    HIT="$(printf '%s' "$TREE" | python3 -c "
import json, sys
pat = sys.argv[1]
d = json.load(sys.stdin)
def walk(n):
    t = n.get('text')
    b = n.get('bounds') or []
    if t and pat in t and len(b) == 4:
        return (b[0] + b[2] / 2, b[1] + b[3] / 2)
    for c in (n.get('children') or []):
        r = walk(c)
        if r: return r
    return None
hit = None
for n in d.get('nodes', []):
    hit = walk(n)
    if hit: break
if not hit:
    sys.exit(3)
print(f'{hit[0]} {hit[1]}')
" "$TAP_PAT" 2>&1)" || fail "未找到文本节点: $TAP_PAT" "检查 ui-tree 是否含该子串（tap_text 只匹配 text 节点）"
    TX="$(printf '%s' "$HIT" | cut -d' ' -f1)"
    TY="$(printf '%s' "$HIT" | cut -d' ' -f2)"
    SCREEN="$(curl -sS --max-time 10 -H "$AUTH" "$BASE/debug/action" \
      -X POST -H "$CONTENT" -d '{"action":"screen","args":{}}' 2>&1)" \
      || fail "screen 端点请求失败" "$SCREEN"
    DPR="$(printf '%s' "$SCREEN" | grep -o '"dpr":[0-9.]*' | cut -d: -f2)"
    [ -n "$DPR" ] || fail "screen 端点未返回 dpr" "$SCREEN"
    PX="$(awk "BEGIN{printf \"%d\", $TX * $DPR}")"
    PY="$(awk "BEGIN{printf \"%d\", $TY * $DPR}")"
    echo "[tap_text] '$TAP_PAT' → logical($TX,$TY) ×dpr($DPR) → device($PX,$PY)"
    adb -s "$DEVICE" shell input tap "$PX" "$PY"
    exit $?
    ;;
  tap_bounds)
    assert_foreground
    SCREEN="$(curl -sS --max-time 10 -H "$AUTH" "$BASE/debug/action" \
      -X POST -H "$CONTENT" -d '{"action":"screen","args":{}}' 2>&1)" \
      || fail "screen 端点请求失败" "$SCREEN"
    DPR="$(printf '%s' "$SCREEN" | grep -o '"dpr":[0-9.]*' | cut -d: -f2)"
    [ -n "$DPR" ] || fail "screen 端点未返回 dpr" "$SCREEN"
    X="$(printf '%s' "$BOUNDS" | cut -d, -f1)"
    Y="$(printf '%s' "$BOUNDS" | cut -d, -f2)"
    W="$(printf '%s' "$BOUNDS" | cut -d, -f3)"
    H="$(printf '%s' "$BOUNDS" | cut -d, -f4)"
    if [ -n "$W" ] && [ -n "$H" ]; then
      X="$(awk "BEGIN{print $X + $W/2}")"; Y="$(awk "BEGIN{print $Y + $H/2}")"
    fi
    PX="$(awk "BEGIN{printf \"%d\", $X * $DPR}")"
    PY="$(awk "BEGIN{printf \"%d\", $Y * $DPR}")"
    echo "[tap_bounds] logical($X,$Y) ×dpr($DPR) → device($PX,$PY)"
    adb -s "$DEVICE" shell input tap "$PX" "$PY"
    exit $?
    ;;
  wait_log)
    DEADLINE=$(( $(date +%s) + WAIT_TMO ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
      HIT="$(adb -s "$DEVICE" logcat -d 2>/dev/null | grep -aE "$WAIT_PAT" | tail -1)"
      if [ -n "$HIT" ]; then printf '%s\n' "$HIT"; exit 0; fi
      sleep 2
    done
    fail "wait_log 超时（${WAIT_TMO}s）未匹配: $WAIT_PAT" \
      "确认设备时间线/触发动作是否已执行；先 device-log 看最新日志"
    ;;
  device_log)
    if [ -n "$DL_PAT" ]; then
      adb -s "$DEVICE" logcat -d 2>/dev/null | grep -aE "$DL_PAT" | tail -"$DL_TAIL"
    else
      adb -s "$DEVICE" logcat -d 2>/dev/null | tail -"$DL_TAIL"
    fi
    exit 0
    ;;
  foreground)
    FG="$(foreground_pkg)"
    case "$FG" in
      "$APP_PACKAGE"*) ISG=true ;;
      *) ISG=false ;;
    esac
    if [ "$ISG" = true ]; then HINT="宿主 app 前台（$APP_PACKAGE）——用桥面命令（tap_bounds/ui-tree/action）"; \
    else HINT="非宿主 app 前台（${FG:-unknown}）——桥面 UI 命令会命中错误界面，改用 system-ui + system-tap 驱动系统层"; fi
    printf '{"foreground":"%s","is_goodhub":%s,"hint":"%s"}\n' "${FG:-unknown}" "$ISG" "$HINT"
    exit 0
    ;;
  system_ui)
    # dump→cat 留 flush 窗口（FUSE 存储竞态：紧贴偶发读到空文件，2026-11-05
    # 真机实证）；exec-out 比 shell 二进制安全。
    adb -s "$DEVICE" shell uiautomator dump /sdcard/gh_wd.xml >/dev/null 2>&1
    sleep 1
    XML="$(adb -s "$DEVICE" exec-out cat /sdcard/gh_wd.xml 2>/dev/null)"
    adb -s "$DEVICE" shell rm -f /sdcard/gh_wd.xml >/dev/null 2>&1
    [ -n "$XML" ] || fail "取不到 UI dump XML" "uiautomator dump 空——可能正在动画，稍候重试"
    # XML 走临时文件参数，stdin 专供 heredoc 脚本——`python3 - <<PY` 会从
    # stdin 读脚本，若同时管道喂 XML 则争抢 stdin，sys.stdin.read() 读到空
    # （2026-11-05 真机实证「no element found」根因）。
    XMLF="$(mktemp -t gh_wd_XXXXXX.xml)"
    printf '%s' "$XML" > "$XMLF"
    python3 - "$SU_SUB" "$XMLF" <<'PY'
import sys, json, xml.etree.ElementTree as ET
sub, xmlfile = sys.argv[1], sys.argv[2]
try:
    root = ET.fromstring(open(xmlfile, encoding='utf-8').read())
except ET.ParseError as e:
    print(json.dumps({"ok": False, "error": "xml_parse", "detail": str(e)})); sys.exit(1)
def center(b):
    try:
        xs, ys = b.strip("[]").split("][")
        x1, y1 = map(int, xs.split(",")); x2, y2 = map(int, ys.split(","))
        return {"x": (x1+x2)//2, "y": (y1+y2)//2, "w": x2-x1, "h": y2-y1}
    except Exception:
        return None
out = []
for n in root.iter("node"):
    text = n.get("text",""); desc = n.get("content-desc","")
    lab = text or desc
    if not lab: continue
    if sub and sub not in lab: continue
    b = center(n.get("bounds",""))
    if b is None: continue
    out.append({"label": lab[:120], "clickable": n.get("clickable")=="true",
                "class": n.get("class","").split(".")[-1], **b})
print(json.dumps({"ok": True, "count": len(out), "nodes": out}, ensure_ascii=False, indent=1))
PY
    rm -f "$XMLF"
    exit 0
    ;;
  system_tap)
    FG="$(foreground_pkg)"
    case "$FG" in
      "$APP_PACKAGE"*) echo "[system-tap] 注意：当前前台是宿主 app（$APP_PACKAGE）——若目标是系统 UI 可能已关闭；如需点宿主用 tap_bounds" ;;
      *) echo "[system-tap] 前台: ${FG:-unknown}（系统/第三方 UI，符合预期）" ;;
    esac
    adb -s "$DEVICE" shell input tap "$ST_X" "$ST_Y"
    exit $?
    ;;
esac

if [ -n "$BODY" ]; then
  # action POST 可经 DBG_HTTP_TIMEOUT 放宽（默认 10s）：慢动作（drain_supply_pool
  # / query_on_device 同步等端侧推理完成）由调用方显式放宽，GET 面保持 10s
  # 快失败——与 goodhub 统一入口同参数（副本分叉守卫：两处同步改）。
  OUT="$(curl -sS --max-time "${DBG_HTTP_TIMEOUT:-10}" -X POST -H "$AUTH" -H "$CONTENT" -d "$BODY" "$URL" 2>&1)" \
    || fail "端点请求失败" "$OUT"
else
  OUT="$(curl -sS --max-time 10 -H "$AUTH" "$URL" 2>&1)" \
    || fail "端点请求失败" "$OUT"
fi
printf '%s\n' "$OUT"
