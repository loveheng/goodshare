---
dev-loop: devlog
format: v1
epic: misc
total-merged: 0
last-merge: none
---

（散修/小改动按行追加；≥5 条自动归并进 memory.md）
- [2026-09-30] [变更]: 全局 devlog 记账脚本落地（toolbox devlog.sh：change/verify/note/lesson/bp/count 六子命令，--json 预检不落盘、幂等去重、单趟 awk 断点替换+恒1行校验、自测 11 条沙箱断言；金丝雀曾逮住日期格式缺方括号 bug 后修复）；dev-loop SKILL 实现口径与断点规则已指针化到该工具（保留 cat>>/sed 降级路径）
- [2026-09-30] [验证]: sh devlog.sh --self-test → 11/11 通过；toolbox check → exit 0 已登记；goodshare 真实冒烟 count=5/--json 预检正常
