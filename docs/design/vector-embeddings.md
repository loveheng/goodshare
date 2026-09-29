---
status: draft
updated: 2026-09-29
---

# 向量检索与派生数据策略（预留设计）

> 面向「文本 / 音视频转写内容做摘要 + 向量化」的检索演进预留。当前尚无向量产出引擎——本页先固化**派生数据治理**（已于 schema v9 落地）与两条接入时执行的约定（int8 量化、检索路径分档），核心原则：**派生数据与事实源严格分表，前者永远可再生，备份只保护后者**。
> 拍板于 2026-09-29（用户拍板：派生数据分表即日落地，量化与检索路径记档）。

## 1. 派生数据治理（已落地，schema v9）

### 1.1 item_embeddings 独立派生表

```text
item_embeddings (
  item_id     TEXT NOT NULL REFERENCES inbox_items(id) ON DELETE CASCADE,
  model       TEXT NOT NULL,   -- 嵌入模型标识（换模型 = 全量重算，旧档先清）
  chunk_index INTEGER NOT NULL,-- 分块序号 0 起（短条目整条一向量恒 0）
  dim         INTEGER NOT NULL,
  dtype       TEXT NOT NULL DEFAULT 'f32',  -- f32 / int8
  vec         BLOB NOT NULL,   -- 小端 float32 / int8 量化字节
  created_at  INTEGER NOT NULL,
  PRIMARY KEY (item_id, model, chunk_index)
)
```

分表的理由（对齐「摘要/译文亦是派生物」的延伸认知）：

- **事实源体积不随向量增长**——主库四表（inbox_items / ai_task_queue / daily_metrics / drafts）只存文本与元数据，个人十年用量也在百 MB 以内；向量一旦入库会让库体积被派生数据主导。
- **换模型即整表重算**——嵌入模型迭代（换档、升维、量化切换）时删除旧 `model` 档全量重算，不迁移、不兼容旧向量。
- **备份/恢复把整表当缓存**：`Repository.snapshotTo` 在快照副本上清空 item_embeddings（向量**不进备份**，见 [s3-backup.md](s3-backup.md) §9）；`restoreFrom` 在替换事实源的同一事务里清空本地向量——旧向量指向恢复前的条目世界，stale 即清。恢复语义恒为「事实源全量替换 + 派生缓存归零」。
- 条目硬删除（purge）经外键 CASCADE 自动清理，不留孤儿向量。

### 1.2 体积测算（个人用量量级）

| 层 | 单位体积 | 量级估算（每天 20 条、十年） |
|---|---|---|
| 文本各层（正文/human_md/译文/摘要） | ~5-6KB/条 | 几十 MB |
| 转写文本（1 小时音视频逐字稿） | ~45KB/条 | 偶发项，非日常 |
| FTS 索引 | 文本 ×1.5 | +几十 MB |
| 向量（整条目一向量，1024d f32） | 4KB/条 | ~30MB |
| 向量（分块嵌入，仅长文本） | 500 字/块 ≈ 4KB/块 | 长转写 1h ≈ 120KB/条 |

结论：文本层可忽略；**分块嵌入是唯一需要纪律的层**——分块只对长文本（转写、长文档）做，短条目整条一向量；int8 量化再省 4 倍（见 §2）。

## 2. 量化约定（接入时执行）

- 端侧嵌入模型**优先取 int8 量化输出**：1024 维 4KB(f32) → 1KB(int8)，个人规模检索精度损失无感。
- 表结构已预留 `dtype` 列（`f32` / `int8`），量化切换**不需要迁移**，按 model 档全量重算即可。
- 读取侧必须校验 `dim` 与 `dtype` 匹配的期望字节数，不匹配的档视为待重算。

## 3. 检索路径演进（分档）

| 档 | 触发条件 | 方案 |
|---|---|---|
| 第一档（默认） | 向量 ≤ ~1 万行 | **Dart 暴力余弦**——sqflite 不带 sqlite-vec 扩展，万级 × 1024d 扫描为几十 ms 级，足够 |
| 第二档（再议） | ≥ ~10 万行 | sqlite-vec 原生扩展或分块倒排/聚类索引；届时评估扩展加载路径（sqflite 自定义ffi / 独立原生通道） |

个人十年用量大概率停在第一档；第二档是触发式升级，不预设。

## 4. 代码落点

| 文件 | 职责 |
|---|---|
| `lib/data/db.dart` | schema v9：item_embeddings 建表 + 幂等迁移 `_ensureEmbeddingsTable` |
| `lib/data/repository.dart` | `replaceItemEmbeddings`（按模型整替）/ `deleteItemEmbeddings` / `embeddingsCount`；`snapshotTo` 快照清空向量、`restoreFrom` 事务内清 stale 向量 |
| `docs/design/s3-backup.md` | §9 派生数据不进备份的交叉引用 |

嵌入引擎（模型选型、分块策略、队列动作、MCP 工具）未设计——接入时另立设计页，本文档只约束其必须遵守的存储与备份语义。
