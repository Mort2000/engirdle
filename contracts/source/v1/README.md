# Source parsing contract v1

原文（Markdown / 纯文本）结构化的跨端契约：PC 用 `engirdle-gfm@1`（markdown-it-py，CommonMark + table + strikethrough），mobile 用 Dart 手写解析器 `engirdle-gfm-dart@1`。两端不共享运行时代码，而是通过**同一批黄金 fixture** 证明对同一输入产出完全相同的块/句/runs 结构与 `structure_sha256`（轻量文章包设计 §6.4）。

## 契约内容

- `fixtures/*.md`：输入语料（LF；`crlf.md` 特意携带 CRLF 证明换行规范化一致）。fixture 文件按字节保存，git 不做换行转换（见仓库 `.gitattributes`）。
- `fixtures/expected/*.json`：由 PC 管线生成的期望输出（`parser_version`、`segmenter_version`、`source_sha256`、`normalized_sha256`、`structure_sha256`、`warnings`、`blocks`）。块形状与 `structure_sha256` 哈希载荷完全一致。
- `fixtures/reject/*.md` + `expected/reject-*.json`：两端都必须拒绝的输入（HTML 块/行内、空正文、形似 HTML 的尖括号）。
- `tools/generate_fixtures.py`：重新生成期望文件（在 PC 环境运行）。

## 对齐规则（两端一致）

1. `source_sha256` 对原始字节；canonical 仅统一换行（CRLF/CR → LF），不做其他改写；`normalized_sha256` 对 canonical。mobile 对粘贴/文件输入额外剥除 BOM（PC 入口无此场景），fixture 语料均无 BOM，故不影响对齐。
2. 可见文本策略：NFKC → 智能字符映射（‘’“”–— 和 NBSP）→ 过滤 Cc 控制字符（保留 \n \t）；不适用于代码块、行内代码与链接 URI。
3. 分句：`.!?` 结束符、连续结束符合并、右随标点并入、下一字符小写则不断句；`.` 的十进制/缩写（dr, e.g, fig, i.e, jr, mr, mrs, ms, no, prof, sr, st, vs）/单大写字母/多点缩写规则见 PC `markdown.py`。
4. ID 分配：`block-N` / `sentence-N` 按解析器内部分配顺序（嵌套内容先于父项），`order` 最终按文档位置重排；表格 cell 为 `cell-{block}-{i}`，补齐格为 `cell-{block}-pad-{k}`。
5. 结构哈希：块载荷 canonical JSON（`sort_keys`、`ensure_ascii=False`、紧凑分隔符）的 SHA-256，见 PC `structure.py`。
6. 资源上限沿用 PC `MarkdownLimits`。

## mobile 子集收窄（明确拒绝）

mobile 解析器接受**不宽于** PC 的子集；对以下 PC 可接受、但两端实现无法稳定对齐的语法，mobile 明确拒绝并给出可操作错误（设计 §6.4「缩小子集并明确拒绝差异语法」）：

| 语法 | 拒绝原因 |
|---|---|
| 链接引用定义 `[label]: url` | 引用式链接的解析在两端最难对齐；拒绝定义后，方括号字面量语义两端一致 |
| 行内 autolink `<https://…>` | markdown-it 解析 scheme 规则复杂；移动端拒绝，裸 URL 文本两端一致 |
| HTML 实体 `&amp;` 等 | 实体表庞大；拒绝合法实体引用，字面 `&` 两端一致 |

HTML 块/行内（两端都拒绝）、空正文（两端都拒绝）见 `fixtures/reject/`。纯文本（`.txt`/粘贴纯文本）结构化是 mobile 专属路径（PC 无纯文本入口），由 mobile 单测覆盖，规则为：空行分块 + 本契约第 2/3 条。

## 消费方

- PC：`apps/pc/tests/contract/source/test_source_fixtures.py`
- mobile：`apps/mobile/test/contracts/source_fixtures_test.dart`

契约变更（新增/修改 fixture、修改规则）必须在同一提交中更新两端实现与期望文件。
