# Engirdle 跨端契约

`contracts` 是 PC 生产端与移动消费端之间的唯一规范源。本目录只包含语言无关的 JSON Schema、可阅读示例和黄金测试制品；两端的 Pydantic/Dart 映射属于各自应用。

文档中的“必须”、“应”和“可以”分别表示强制要求、推荐要求和可选行为。如果本目录与 `.scratch/mvp/mvp_design.md` 冲突，以后者为准并同步修正契约。

## 契约族

| 契约 | 内容 | 入口 |
|---|---|---|
| Readpack v1 | ZIP 布局、manifest、文章、归属和安全导入规则 | [`readpack/v1`](./readpack/v1/) |
| Catalog v1 | 局域网只读目录与当前发布制品 | [`catalog/v1`](./catalog/v1/) |
| Dictionary v1 | 历史离线词典资源包契约 | [`dictionary/v1`](./dictionary/v1/) |
| Dictionary v2 | OEWN sense 与 Chinese Open Wordnet lemma 的 ILI 对齐 | [`dictionary/v2`](./dictionary/v2/) |

## 验证层次

消费者必须按以下层次验证，不得把“JSON Schema 通过”等同于“包可安全导入”：

1. 传输层：核对 catalog 声明的 ZIP 字节数和 SHA-256。
2. 容器层：在解压前检查 ZIP 路径、类型、重复项、加密标志和资源上限。
3. 结构层：对 readpack/dictpack 的 `manifest.json`、`article.json`、`attribution.json` 或 `catalog.json` 使用对应 schema。Schema `format` 断言也必须启用。
4. 完整性层：核对 manifest 中每个载荷文件的精确字节数和 SHA-256。
5. 语义层：验证标识一致、唯一性、顺序、引用和音频边界。

JSON 文件必须是无 BOM 的 UTF-8。SHA-256 始终对存储或传输的原始字节计算，不在校验前重新序列化 JSON。十六进制摘要使用 64 位小写字符。

## 兼容性

- `format_version` 使用 `major.minor`。v1 实现必须接受自己已实现的 `1.x` 次版本，并拒绝其他主版本。
- Schema 允许未知 JSON 属性；消费者必须忽略它们，不得据此改变既有语义。
- Readpack manifest 的 `required_capabilities` 列出不可忽略的能力。v1.0 未定义任何此类能力，因此非空列表必须被 v1.0 实现拒绝。v1.1 定义 `markdown-blocks`（类型化标题/表格/代码/分隔线块与行内 runs）；实现必须只接受自己认识的能力，未知能力在提交导入前拒绝。
- 增加可忽略字段只增加 minor；删除字段、改变已有语义、必需文件、ID 规则或签名模型必须增加 major。

变更契约时，必须在同一变更中更新 schema、兼容性说明、有效/无效 fixtures 以及 PC/Flutter 契约测试。
