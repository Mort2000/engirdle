# Readpack v2 兼容性

## 为什么是 major

v1 把固定四文件布局、逐句译文和完整音频设为**必需语义**：每个文本句必须有非空译文和音频边界，`audio/article.m4a` 恒存在。source-only 包无法在不伪造空译文、零时长音频的情况下通过 v1 校验，而仓库兼容规则明确"改变必需文件/语义必须升 major"。因此轻量分层使用 `2.0`，而不是 `1.2` 或平行的 litepack 契约族。

## v2.0

- 必需文件收敛为 `manifest.json`、`article.json`、`attribution.json`；译文、narration 与音频是按描述符声明的可选派生物，实际 ZIP 路径集合必须与 manifest `files` 完全相等。
- manifest 结构变化：`content` 指向 `article.json` 并携带 `structure_sha256`、`parser`、`segmenter`；`derivatives.translations`（零或多个 locale 描述符）与 `derivatives.narration`（可空）取代 v1 的顶层 `audio` 与 `pipeline.translation`/`pipeline.tts`；管线快照移入各派生物自己的 `pipeline` 字段。
- `article.json` 移除全部派生字段（句级 `translation_zh`、音频样本/毫秒边界、表格 `translation_zh`），新增必填 `normalized_sha256`。块判别联合与 v1.1 相同。
- v2.0 客户端不识别任何 `required_capabilities` 值；非空列表必须拒绝（未来 2.x 可定义新能力）。
- attribution 必需资源按派生物条件化（见 README）；v1 的七资源恒必填规则不再适用。
- 校验分层：base、每个 translation 派生物、narration 派生物分别校验，通过 `structure_sha256` 精确绑定；结构哈希不相等时禁止复用、激活或按文本猜测映射。

## 与 v1 的关系

- v1 客户端看到 `format_version` 主版本 `2` 必须拒绝，不会把缺音频的包误判为损坏的 v1 包。
- v2 客户端通过独立的 v1/v2 validator adapter 把两个版本投影到同一个内部领域模型（ArticleBase + 可选 TranslationSet + 可选 NarrationAsset）；v1.0/v1.1 包继续长期可导入，其 packaged 译文投影为一个 `complete` TranslationSet，音频投影为 NarrationAsset。
- PC 在 v2 落地期间继续发布 v1.1；catalog v1 的 `format_version` 约束不变。PC packaging 的 v2 exporter 是后续独立变更，不依赖 translation/speech/audio 模块。

## 未来 2.x

增加可忽略字段（如新的 run kind、新的派生物描述符属性）只升 minor，消费者必须忽略未知属性；删除字段、改变既有语义、ID 规则或派生物完整性规则必须升 major。2.x 客户端遇到更新的 `2.y` 包时，先用自身已知 schema 与语义规则验证：必需文件、已知字段语义未变则忽略未知字段继续，否则在解压或提交导入前拒绝。
