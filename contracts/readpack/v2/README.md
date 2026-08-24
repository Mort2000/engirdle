# Readpack v2

Readpack v2 把 v1 的"完整生产包"分层为**不可变原文基座 + 可选派生物**：一个 source-only 包只有原文结构与归属，译文和语音作为独立派生物按需出现。移动端轻量阅读路径（粘贴原文、本机原文文件）与未来 PC source-only 导出都以本契约为基础。设计动机见 `.scratch/mobile_lightweight_readpack_translation_design.md` §5。

## 逻辑布局

ZIP 只包含 manifest 声明的普通文件，实际路径集合必须与 `files` 声明集合完全相等：

| 路径 | source-only | 含译文 | 含 narration | 语义 |
|---|---:|---:|---:|---|
| `manifest.json` | 必需 | 必需 | 必需 | 信封、文件哈希、派生物描述符 |
| `article.json` | 必需 | 必需 | 必需 | 只含不可变原文结构 |
| `attribution.json` | 必需 | 必需 | 必需 | 原文与处理依赖归属 |
| `derivatives/translation.<locale>.json` | 禁止 | 必需 | 可选 | 完整译文集与翻译管线快照 |
| `derivatives/narration.json` | 禁止 | 可选 | 必需 | 音频描述及句级区间 |
| `audio/article.m4a` | 禁止 | 可选 | 必需 | narration 引用的不可变音频 |

首期 locale 只有 `zh-Hans`，对应路径 `derivatives/translation.zh-Hans.json`。ZIP 不允许显式目录条目、额外文件、空路径、反斜杠、绝对路径、`.`/`..` 分量、规范化后重复路径、链接、设备文件或加密条目；容器与安全规则沿用 v1。压缩算法仍是容器实现细节，导入器必须至少支持 `stored` 和 `deflate`，不得依赖条目顺序或时间戳。

## 数据规则

- `article_id` / `package_id` 是 UUID；`block_id`、`sentence_id`、`cell_id` 是修订内唯一的不透明字符串。
- `revision` / `artifact_revision` 从 1 开始单调递增；块和句子的 `order` 从 0 开始连续且与数组位置一致。
- `article.json` 是纯原文：文本句携带非空 `runs`（拼接后严格等于 `text`），但**不携带任何 `translation_zh` 或音频字段**；表格携带 cell ID、runs、对齐、header 和 rows，但**不携带译文**。块判别联合沿用 v1.1 语义（kind 与负载严格匹配）。
- 顶层新增必填 `normalized_sha256`（规范化原文文本的 SHA-256）；`source_sha256`、`structure_sha256` 语义与 v1 相同。
- 纯代码/分隔线文章合法可读，但没有可翻译单元；含译文派生物的文章必须至少有一个文本句或一张非空表。
- **translation 派生物**：`article.id`/`revision`、`structure_sha256` 必须与 base 完全一致；`sentences` 精确覆盖全部文本句（同序、无缺失、无多余）；`tables` 按块分组、保持每张表 header→rows 的二维 cell 顺序，精确覆盖全部 cell。每条译文非空且不超过 40,000 字符。包内不允许 partial 集合。`pipeline` 记录 provider、model、prompt 版本、thinking/reasoning 配置、生成时间和客户端版本。译文是恢复占位符之后的最终文本，不含 `‰N‰` 占位符。
- **narration 派生物**：`structure_sha256` 必须与 base 一致；`audio` 描述唯一音频（首期固定 M4A/AAC-LC、24000 Hz、单声道）；`sentences` 精确覆盖 base 的全部可朗读文本句，样本区间 `[start, end)` 非空、单调、不重叠且不超过音频总长；毫秒边界由样本边界换算（`floor(start*1000/rate)` / `ceil(end*1000/rate)`）。表格、代码与分隔线永不出现。
- manifest 的 `content.structure_sha256` 必须等于 `article.json` 的 `structure_sha256`；manifest、article 与各派生物的文章 ID/修订完全一致；`derivatives.narration` 存在时必须同时声明 `derivatives/narration.json` 与 `audio/article.m4a`，反之 `files` 不得携带音频或 narration 文件。`content.parser` 对 Markdown 原文必填、对纯文本原文缺省（纯文本没有 parser）。
- v2 不使用 `profile` 枚举组合；能力由派生物描述符的存在与完整校验结果推导。`required_capabilities` 只表达不可忽略的语法/语义扩展，未知值仍必须拒绝。
- `attribution.json`：`article_source` 与 pipeline `software_dependency` 恒必填；携带 translation 派生物时必须声明 `translation_service`，携带 narration 时必须声明两个 tts 模型、voice profile 与 audio encoder。未知/不适用的来源、版本、许可或修改信息沿用 v1 的 `unknown` / `not_applicable` 规则。

## 资源上限

除以下差异外沿用 v1 上限表（`../v1/README.md`）：ZIP 条目数上限仍为 64，v2 布局实际文件数为 3–5；译文派生物中每条译文上限 40,000 字符。导入器必须先检查中央目录，再在流式解压时独立计数。

## 目录

- `schema/`：五个 JSON Schema 2020-12 文件（manifest、article、attribution、translation、narration）。
- `examples/minimal-source/`：source-only 黄金包的展开后内容。
- `examples/full/`：译文 + narration 齐备的黄金包展开后内容。
- `fixtures/valid/`：四种合法组合（source-only、translated、narrated、full）。
- `fixtures/invalid/`：必须在写入最终目录前被拒绝的包，预期见 [`fixtures/README.md`](./fixtures/README.md)。

兼容性与 v1 投影规则见 [`COMPATIBILITY.md`](./COMPATIBILITY.md)。
