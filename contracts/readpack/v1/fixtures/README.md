# Readpack v1 fixtures

| Fixture | 预期 | 首个必须命中的原因 |
|---|---|---|
| `valid/minimal.readpack` | 接受 | schema、布局、大小、哈希、引用和音频边界全部合法（v1.0 黄金包） |
| `valid/mixed-markdown.readpack` | 接受 | v1.1 混合 Markdown 包：标题 runs、表格（含整表译文）、代码块和分隔线全部合法 |
| `valid/v10-legacy-list-quote.readpack` | 接受 | v1.0 旧版包：`list_item` 无列表 payload、`quote` 无 `quote_depth`，按文档化默认值解码 |
| `invalid/missing-file.readpack` | 拒绝 | manifest 声明的 `audio/article.m4a` 不存在 |
| `invalid/wrong-hash.readpack` | 拒绝 | `audio/article.m4a` 的实际 SHA-256 与 manifest 不同 |
| `invalid/duplicate-path.readpack` | 拒绝 | ZIP 中出现两个 `article.json` |
| `invalid/path-traversal.readpack` | 拒绝 | ZIP 包含 `../escape.txt` |
| `invalid/oversized-entry.readpack` | 拒绝 | 中央目录声明的单条目展开大小超过 1 GiB |
| `invalid/unsupported-major.readpack` | 拒绝 | manifest 声明未支持的 `format_version: 2.0` |
| `invalid/invalid-article-schema.readpack` | 拒绝 | `article.json` 使用了 v1 未定义的块类型 |
| `invalid/invalid-attribution-schema.readpack` | 拒绝 | `attribution.json` 使用了未定义的归属状态 |
| `invalid/missing-translation.readpack` | 拒绝 | 句子缺失 MVP 发布 profile 必需的中文译文 |
| `invalid/invalid-audio-range.readpack` | 拒绝 | 句子音频样本区间为空 |
| `invalid/article-id-mismatch.readpack` | 拒绝 | manifest 与 article 的文章 ID 不一致 |
| `invalid/unknown-capability.readpack` | 拒绝 | v1.1 包声明了未知必需能力 `frobnicate` |
| `invalid/table-translation-shape.readpack` | 拒绝 | 表格译文的 cell ID 集合与原表不一致 |
| `invalid/code-with-translation.readpack` | 拒绝 | 代码块携带了 `translation_zh` |
| `invalid/empty-runs.readpack` | 拒绝 | v1.1 文本句子 `runs` 为空 |
| `invalid/duplicate-cell-id.readpack` | 拒绝 | 表格 cell ID 重复 |
| `invalid/no-narration.readpack` | 拒绝 | 全文没有任何带音频区间的文本句子 |
| `invalid/v10-with-markdown-blocks.readpack` | 拒绝 | v1.0 包携带了 v1.1 专属块类型 |
| `invalid/divider-with-sentences.readpack` | 拒绝 | `divider` 块携带了 `sentences`（判别联合禁止跨 kind 负载） |

无效包只包含触发对应检查所需的最小差异，不包含大型压缩炸弹。`oversized-entry.readpack` 只修改 ZIP 中央目录的声明大小，导入器必须在尝试解压该条目前拒绝；流式实际字节计数仍应由应用内部单元测试覆盖。
