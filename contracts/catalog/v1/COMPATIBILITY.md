# Catalog v1 兼容性

## v1.0

- Catalog 本身通过 schema 作版本化；每个包的 `format_version` 声明 Readpack 版本。
- v1 实现忽略未知可选字段，但必须拒绝格式错误、不安全 URL、重复文章、重复 URL 和不支持的 Readpack 主版本。
- 未来如果 catalog 需要非忽略型能力，必须新增 catalog 主版本，不得仅用未知字段改变 v1 语义。
