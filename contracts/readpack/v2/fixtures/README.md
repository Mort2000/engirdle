# Readpack v2 fixtures

| Fixture | 预期 | 首个必须命中的原因 |
|---|---|---|
| `valid/source-only.readpack` | 接受 | 三文件 source-only 包：布局、schema、哈希与一致性全部合法 |
| `valid/translated.readpack` | 接受 | source + `zh-Hans` 译文派生物，句子与表格精确覆盖 |
| `valid/narrated.readpack` | 接受 | source + narration 派生物与音频，句级区间合法 |
| `valid/full.readpack` | 接受 | 译文 + narration + 音频齐备的最大组合 |
| `invalid/undeclared-extra-file.readpack` | 拒绝 | ZIP 携带 manifest 未声明的 `notes.txt`，路径集合不相等 |
| `invalid/missing-base-file.readpack` | 拒绝 | manifest 声明 `attribution.json` 但 ZIP 中不存在 |
| `invalid/translation-sentence-missing.readpack` | 拒绝 | 译文派生物缺少 `sentence-3`，覆盖集合不完整 |
| `invalid/translation-structure-mismatch.readpack` | 拒绝 | 译文派生物的 `structure_sha256` 与 base 不一致 |
| `invalid/translation-cell-missing.readpack` | 拒绝 | 表格译文缺少 `cell-3-3`，二维覆盖不完整 |
| `invalid/narration-range-empty.readpack` | 拒绝 | `sentence-2` 的样本区间为空（start == end） |
| `invalid/audio-without-narration.readpack` | 拒绝 | 声明并携带音频文件，但 `derivatives.narration` 为空 |

无效包只包含触发对应检查所需的最小差异。音频复用 v1 示例的短静音 M4A。容器层攻击面（路径穿越、重复条目、超大条目等）由 v1 fixtures 与各应用的安全 ZIP 单元测试覆盖，不在 v2 重复。
