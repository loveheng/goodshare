---
copilot-context: devlog
format: v1
thread: rich-text-gfm
total-merged: 0
last-merge: none
---
- [2026-10-04] [修订]: 起草 R1-R4 修订草案（规格权威/==误判/引用链接采集/序列化契约）追加至 rich-text-gfm.md 末尾，待拍板合并入正文
- [2026-10-04] [评审]: 评估 rich-text-gfm.md draft——落地依据已核验(rich_text.dart 枚举/块级/行内正则顺序与§3.6吻合,***粗斜***残壳实证成立);结论可转active,拍板前消4处不确定性:①§3.4/§3.5规格重复权威冲突②==高亮 a==b误判规则③引用链接[id]采集传入④新标记序列化格式
- [2026-10-04] [修订]: R1-R4 修订草案合并入 rich-text-gfm.md 正文（§3.4 legacy 化、§3.5 定为权威、§2 加 R3 引用链接机制、§3.6 收紧 == 正则+加 ⑥ refDefs 扫描+加序列化契约、§5 验收补用例）；草案小节已移除；doc updated 日期升 2026-10-04
- [2026-10-04] [拍板]: rich-text-gfm.md 由 draft 转 active，进入开发阶段；实现依据锁定（R1-R4 已合并入正文）
- [2026-10-04] [设计]: 评审解析器架构——现状块级为 _parseBlocks 内 if-cascade(逻辑即职责链但未对象化)、行级单条合并正则 allMatches 单次线性扫描;结论:①流式(逐行token流)不采纳(量级小+多行块需状态)②对象化CoR延后到扩展期(加 strikethrough/highlight/table)再启用,收益=加块类型零改核心,代价=每行虚分发+段落聚合反向咨询handler;已落 §3.7 + 草稿 lib/doc/rich_text_coi_draft.dart(scratch,非落地)
