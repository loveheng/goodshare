#!/bin/bash
# arch-guard — 拾贝分层架构 / Human-AI 对称性硬约束机械护栏
#
# toolbox-script
# format: v1
# name: arch-guard
# summary: 拾贝分层架构与无头架构硬约束机械校验（UI 禁直连 repo/禁平台分支/禁裸图片/摄入禁直写/生命周期禁另起 observer/typography 禁裸字面量），改动 lib/ 后与发布前门禁
# trigger: manual
# platform: unix
# cat: test
# alias: ag
#
# 规则口径见 .agents/skills/goodshare-arch/SKILL.md 与 goodshare-ui/SKILL.md；
# 白名单内的条目是**历史例外**，只许减少不许增加（迁移一个删一行）。

set -uo pipefail

ROOT=""
JSON_ONLY=0
SELF_TEST=0
COUNT=0
HITS=""

usage() {
  cat <<'EOF'
用法: arch-guard.sh [选项]        （toolbox run arch-guard [选项] 等价）
  默认: 扫描仓库 lib/ 下 7 条硬约束，逐条打印命中，0=通过 1=有违规
选项:
  --root <目录>  指定仓库根（默认 git 顶层 / 当前目录）
  --json         只输出一行 JSON 结论（供 AI/钩子判定，不打印明细）
  --self-test    金丝雀自测：造已知坏样本，证明"能抓到坏"
  -h, --help     本帮助
说明: 裸跑=逐条明细（人看）；--json=单行结论（机器看）。两者扫描规则完全一致。
EOF
}

die() { echo "ERROR: $*" >&2; exit 2; }

resolve_root() {
  if [ -n "$ROOT" ]; then printf '%s\n' "$ROOT"; return; fi
  local here d
  here=$(cd "$(dirname "$0")" && pwd)
  d=$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)
  printf '%s\n' "${d:-$PWD}"
}

# scan_pattern <id> <作用域(空格分隔)> <描述> <正则> <白名单相对路径(空格分隔)>
scan_pattern() {
  local id="$1" scopes="$2" desc="$3" pattern="$4" wl="$5"
  local dirs="" d
  for d in $scopes; do
    [ -d "$ROOT/$d" ] && dirs="$dirs $ROOT/$d"
  done
  [ -z "$dirs" ] && return 0
  local out line rel rest lineno code
  out=$(grep -rnE --include='*.dart' --exclude='*.g.dart' --exclude='*.freezed.dart' \
        "$pattern" $dirs 2>/dev/null || true)
  [ -z "$out" ] && return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    rel=${line%%:*}; rest=${line#*:}; lineno=${rest%%:*}; code=${rest#*:}
    rel=${rel#"$ROOT/"}
    case " $wl " in *" $rel "*) continue ;; esac
    code=$(printf '%s' "$code" | cut -c1-72 | tr -d '"')
    HITS="${HITS}FAIL ${rel}:${lineno} [${id}] ${desc}\n        ${code}\n"
    COUNT=$((COUNT + 1))
  done <<EOF
$out
EOF
}

scan_all() {
  COUNT=0
  HITS=""
  # R1 UI 层禁止直连 Repository 写方法 —— 写必走 ItemActionHandler.execute
  scan_pattern "R1-ui-repo-write" "lib/pages lib/ui" \
    "UI 层直连 Repository 写方法，写路径必须组装 ItemCommand 交 ItemActionHandler" \
    '\brepo\.(add|update|enqueueTask|softDelete|deleteForever|restore|delete)\(' ""
  # R2 UI 层禁止内联 JSON 编解码
  scan_pattern "R2-ui-json-codec" "lib/pages lib/ui" \
    "UI 层内联 jsonDecode/jsonEncode，应委托下层或 *Store" \
    '\bjson(Decode|Encode)\(' "lib/ui/item_view_template.dart"
  # R3 UI 层禁止平台分支
  scan_pattern "R3-ui-platform" "lib/pages lib/ui" \
    "UI 层出现 Platform.isX 分支，平台差异须收敛到接口实现/工厂" \
    'Platform\.is[A-Z]' ""
  # R4 禁止裸 Image.file/Image.network（统一 GoodshareImage 声明解码尺寸）
  # 前缀断言 [^a-zA-Z] 防止 GoodshareImage.network( 的子串误报
  scan_pattern "R4-raw-image" "lib/pages lib/ui" \
    "裸 Image.file/Image.network，改用 GoodshareImage 并显式 cacheWidth" \
    '(^|[^a-zA-Z])Image\.(file|network)\(' "lib/ui/goodshare_image.dart lib/ui/image_annotator.dart lib/ui/item_view_template.dart"
  # R5 摄入路径禁止直连 Repository 写
  scan_pattern "R5-share-repo-write" "lib/share" \
    "摄入层直连 Repository 写，须走 CollectCommand / AppendSegmentCommand" \
    '\brepo\.(add|update|enqueueTask)\(' ""
  # R6 禁止另起 WidgetsBindingObserver（统一 AppLifecycleManager）
  scan_pattern "R6-lifecycle-observer" "lib" \
    "直接混用 WidgetsBindingObserver，退后台行为须订阅 AppLifecycleManager" \
    'with WidgetsBindingObserver' "lib/app/lifecycle_manager.dart"
  # R7 排版禁用已弃用 textScaleFactor + 裸 fontSize 字面量
  # 白名单：pdf_export.dart——pdf 包的 TextStyle.fontSize 是 PDF 文档排版
  # 参数（毫米级渲染），与 Flutter textTheme/textScaler 无关，规则不适用。
  scan_pattern "R7-typography" "lib/pages lib/ui" \
    "裸 fontSize/textScaleFactor 字面量，须映射 M3 textTheme 并用 textScaler" \
    '(fontSize:|textScaleFactor:)' "lib/pages/mcp_page.dart lib/ui/image_annotator.dart lib/ui/pdf_export.dart"
  return 0
}

report_text() {
  if [ "$COUNT" -eq 0 ]; then
    echo "OK: 7 条架构硬约束全部通过（$ROOT）"
    return 0
  fi
  printf '%b' "$HITS"
  echo "----"
  echo "FAIL: $COUNT 处违规"
  echo "[remedy] 逐条对照 .agents/skills/goodshare-arch/SKILL.md 的「反模式」小节改；"
  echo "[remedy] 确认是历史遗留且暂不迁移的，加进脚本白名单并注明原因（只减不增）"
  return 1
}

report_json() {
  local msg remedy
  if [ "$COUNT" -eq 0 ]; then
    printf '{"status":"OK","severity":"info","message":"arch-guard: 7 条架构硬约束全部通过"}\n'
    return 0
  fi
  msg="arch-guard: $COUNT 处架构硬约束违规（R1 UI直连repo写 / R2 UI内联json / R3 UI平台分支 / R4 裸Image / R5 摄入直写repo / R6 另起生命周期observer / R7 裸排版字面量）"
  remedy="裸跑 toolbox run arch-guard 看逐条明细；对照 goodshare-arch SKILL.md 反模式小节修正，历史遗留加白名单并注明原因"
  printf '{"status":"FAIL","severity":"error","message":"%s","remedy":"%s"}\n' "$msg" "$remedy"
  return 1
}

self_test() {
  local bad clean rc
  bad=$(mktemp -d); clean=$(mktemp -d)
  trap 'rm -rf "$bad" "$clean"' RETURN

  mkdir -p "$bad/lib/pages" "$bad/lib/ui" "$bad/lib/share" "$bad/lib/app"
  cat >"$bad/lib/pages/bad_page.dart" <<'EOF'
await repo.add(item);
if (Platform.isAndroid) {}
child: Image.file(File(p)),
Text('x', style: TextStyle(fontSize: 13)),
EOF
  cat >"$bad/lib/ui/bad_widget.dart" <<'EOF'
final m = jsonDecode(s);
EOF
  cat >"$bad/lib/share/bad_intake.dart" <<'EOF'
await repo.add(item);
EOF
  cat >"$bad/lib/app/bad_obs.dart" <<'EOF'
class BadObs with WidgetsBindingObserver {}
EOF

  mkdir -p "$clean/lib/pages" "$clean/lib/ui"
  cat >"$clean/lib/pages/ok_page.dart" <<'EOF'
final r = await widget.handler.execute(const UpdateItemCommand(id: 1));
EOF
  cat >"$clean/lib/ui/ok_widget.dart" <<'EOF'
child: GoodshareImage(path: p, cacheWidth: 96),
EOF

  ROOT="$bad"; scan_all
  if [ "$COUNT" -lt 7 ]; then
    echo "SELF-TEST FAIL: 坏样本只抓到 $COUNT 处（期望 >=7）" >&2
    printf '%b' "$HITS" >&2
    return 2
  fi

  ROOT="$clean"; scan_all
  if [ "$COUNT" -ne 0 ]; then
    echo "SELF-TEST FAIL: 干净样本误报 $COUNT 处" >&2
    printf '%b' "$HITS" >&2
    return 2
  fi

  echo "SELF-TEST PASS: 坏样本抓到违规、干净样本零误报"
  return 0
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="${2:-}"; [ -n "$ROOT" ] || die "--root 缺参数"; shift 2 ;;
      --json) JSON_ONLY=1; shift ;;
      --self-test) SELF_TEST=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  done

  if [ "$SELF_TEST" -eq 1 ]; then
    self_test; exit $?
  fi

  ROOT=$(resolve_root)
  [ -d "$ROOT/lib" ] || die "未在仓库根找到 lib/：$ROOT（用 --root 指定）"

  scan_all
  if [ "$JSON_ONLY" -eq 1 ]; then report_json; else report_text; fi
}

main "$@"
