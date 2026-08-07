# Catalog v1 fixtures

| Fixture | 预期 | 首个必须命中的原因 |
|---|---|---|
| `valid/minimal.json` | 接受 | schema 和唯一性规则全部合法 |
| `invalid/duplicate-article.json` | 拒绝 | 同一 `article_id` 出现两次 |
| `invalid/duplicate-url.json` | 拒绝 | 两个条目指向同一不可变 URL |
| `invalid/unsafe-url.json` | 拒绝 | URL 不是 `/packages/{opaque-name}.readpack` 安全路径 |
| `invalid/cross-origin-url.json` | 拒绝 | 绝对 URL 与获取 catalog 的 `http://192.0.2.10:8766/catalog.json` 不同源 |
| `invalid/unsupported-major.json` | 拒绝 | 包声明未支持的 Readpack 主版本 |

重复文章、重复 URL 和绝对 URL 的同源性属于语义校验，不能只依赖 JSON Schema。
