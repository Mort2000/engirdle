# Translation v1 fixtures

## golden/

`article.json` 是语言中立的输入：一个标题句块、含行内 code 与 autolink 的双句段落、2×2 表格（含 code cell）、代码块与分隔线。`expected_messages.json` 是该文章经协议投影的完整消息序列（system 原文、source context 字符串、每个 unit 的请求字符串）。实现必须从 `article.json` 逐字节重现 `expected_messages.json`。

## responses/

| 文件 | 对应 unit | 预期 |
|---|---|---|
| `valid/sentence-array.json` | `block-1`（1 句） | 解析通过，占位符验证通过（无占位符） |
| `valid/sentence-fenced.txt` | `block-1` | BOM + 单层 fence 剥离后与 `sentence-array.json` 等价 |
| `valid/table-object.json` | `block-3` | 形状、cell ID 位置与 `‰0‰` 占位符全部通过 |
| `invalid/sentence-wrong-length.json` | `block-1` | 响应长度 2 ≠ 请求长度 1 |
| `invalid/sentence-empty-item.json` | `block-1` | 空白字符串不是合法译文 |
| `invalid/table-cell-added.json` | `block-3` | 多出 `cell-3-4`，形状变化 |
| `invalid/prose-wrapped.txt` | `block-1` | prose 包裹不是可剥离的一层 fence |
| `invalid/table-damaged-placeholder.txt` | `block-3` | `‰0‰` 被改为非规范拼写 `‰00‰` |
