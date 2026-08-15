# Readpack v1 兼容性

## v1.0

- 必需文件固定为 `manifest.json`、`article.json`、`attribution.json` 和 `audio/article.m4a`。
- 必需 JSON 属性由 v1 schema 的 `required` 声明。未知属性被视为可忽略扩展。
- `required_capabilities` 为空或缺省；v1.0 实现必须拒绝任何非空值。
- 块 `kind` 仅为 `paragraph`、`list_item`、`quote`，且每块必须携带 `sentences`。
- v1.0 的 `list_item` 不携带列表 payload、`quote` 不携带 `quote_depth`；新版客户端按文档化默认值解码（`list_kind: bullet`、`list_depth: 0`、`quote_depth: 1`），不得因此拒绝合法旧包。
- 唯一支持的音频布局是单文件 M4A/AAC-LC、24000 Hz、单声道。
- SHA-256 只保证一致性，v1 不包含发布者签名或身份认证。

## v1.1（markdown-blocks）

v1.1 保持 v1.0 的四文件布局和音频格式，新增类型化 Markdown 块联合与行内 runs：

- `format_version` 为 `1.1`，manifest 与 article 必须声明一致的 `required_capabilities: ["markdown-blocks"]`。
- v1.0 客户端因未知必需能力而安全拒绝，不会把表格或代码误渲染为普通句子；新版客户端完整支持 v1.0，对未知 capability 继续拒绝。
- 块 `kind` 判别联合（负载与 kind 严格匹配：携带其他 kind 的已知字段在写入正式目录前拒绝；未知字段仍按可忽略扩展处理）：
  - `paragraph` / `heading`（`level` 1–6）/ `list_item`（`list_kind`、`list_depth`、可选 `list_ordinal`）/ `quote`（`quote_depth` 1–4）携带 `sentences`，每句必须有非空译文和完整音频边界；
  - `table` 携带 `alignments`、`header`、`rows` 和同形状的 `translation_zh`（cell ID 集合一致），禁止任何音频字段；
  - `code` 携带可选 `language` 和非空 `code`，禁止译文与音频；
  - `divider` 无类型专属内容，禁止译文与音频。
- v1.1 文本句子必须携带非空 `runs`（无格式句子使用单个 plain run）；run 的 `text` 拼接后必须严格等于句子 `text`。v1.0 句子无 runs，消费者按单个 plain run 处理。
- 表格 cell 的 `runs` 拼接后必须等于 cell `text`；cell ID 在修订内唯一。
- 资源上限在 PC 冻结、PC Readpack 校验和移动导入三处使用同一契约值：单代码块 512 KiB UTF-8 字节、全文档代码合计 2 MiB UTF-8 字节、单表可见字符 200,000（design §4.4）。
- 语义校验：kind 与 payload 匹配、时间边界单调不重叠且只覆盖可朗读句子、全文至少一个带合法音频区间的文本句子、v1.0 包不得携带 v1.1 专属块、未知 kind 或 capability 在写入正式目录前拒绝。
- 移动端不得依据 pipeline metadata 分支业务渲染；代码块内容按纯文本渲染，永不解释为 HTML。

v1.0 消费者处理未来 `1.x` 时，应先用自身已知 schema 和语义规则验证：只要必需能力为空、必需文件和已知字段语义未变，就忽略未知字段并继续；否则在解压或提交导入前拒绝。
