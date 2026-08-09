# Dictionary pack v2

`.dictpack` v2 为现有 Open English WordNet 义项补充 Chinese Open Wordnet 对译词。正式产品 ID 仍为 `engirdle-en-zh`，固定输入为 `oewn-2025` 与 `omw-cmn:2.0`。

## 数据语义

- `entries` 中每一行都是 OEWN 2025 sense；中文源不得创建独立词条。
- `sense_translations` 只保存与该英文 sense 的 synset 具有相同 ILI 的中文 lemma。
- 每条中文 lemma 同时保留上游原值、展示值、COW sense ID、来源和顺序。展示值只移除 `+的`、`+地` 形态标记。
- 没有完全相同 ILI 时不生成中文对译；不得按词头猜测、机器翻译或人工补配。
- `forms` 只索引 OEWN 词形，不建立中文索引或反向查询。

## 容器与数据库

包内只允许 `manifest.json`、`dictionary.db` 和 manifest 列出的 `licenses/*.txt`。数据库必须包含：

- `entries`、`forms`、`sense_translations`、`dictionary_meta`；
- `idx_entries_headword_order`、`idx_entries_normalized_order`、`idx_forms_normalized_order`、`idx_sense_translations_sense_order`。

规范化版本继续使用 `unicode-nfc-lower-v1`。Schema 位于 [`schema/manifest.schema.json`](./schema/manifest.schema.json)，兼容性见 [`COMPATIBILITY.md`](./COMPATIBILITY.md)。
