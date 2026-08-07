# Readpack v1 兼容性

## v1.0

- 必需文件固定为 `manifest.json`、`article.json`、`attribution.json` 和 `audio/article.m4a`。
- 必需 JSON 属性由 v1 schema 的 `required` 声明。未知属性被视为可忽略扩展。
- `required_capabilities` 为空或缺省；v1.0 实现必须拒绝任何非空值。
- 唯一支持的音频布局是单文件 M4A/AAC-LC、24000 Hz、单声道。
- SHA-256 只保证一致性，v1 不包含发布者签名或身份认证。

v1.0 消费者处理未来 `1.x` 时，应先用自身已知 schema 和语义规则验证：只要必需能力为空、必需文件和已知字段语义未变，就忽略未知字段并继续；否则在解压或提交导入前拒绝。
