# Catalog v1

`catalog.json` 是局域网发布端的只读目录。同一 `article_id` 只能出现一次，并指向当前已成功发布的不可变制品；可选 `dictionaries` 数组发布独立词典资源。

## 语义规则

- `catalog_version` 从 1 开始；当任何对外可见目录内容改变时必须增加。
- 对同一文章，先比较 `revision`，再比较 `artifact_revision`；任一值更高都表示有新制品。
- `size` 和 `sha256` 描述完整 `.readpack` ZIP 的原始字节。
- v1 允许 `/packages/{opaque-name}.readpack` 形式的服务根相对 URL，也允许同路径形式的绝对 HTTP(S) URL。对绝对 URL，消费者必须与本次 catalog 请求 URL 比较规范化后的 scheme、host 和有效端口，不同源时拒绝；URL 不得包含用户信息、query 或 fragment。发布者不得用标题直接生成文件名。
- `packages` 中的 `article_id` 和 `url` 必须分别唯一。
- `dictionaries` 是可选字段；其中 `dictionary_id` 和 URL 分别唯一，URL 只允许同源 `/dictionaries/{opaque-name}.dictpack`。当前发布的词典格式为 Dictpack 2.x；旧客户端忽略该字段，文章导入不依赖词典存在。
- 目录失败或回退不得破坏移动端已安装内容。实现不得仅因远端条目消失就删除本地文章。

Schema 使用 JSON Schema 2020-12。可阅读示例在 `examples/catalog.json`，测试输入和预期在 [`fixtures/README.md`](./fixtures/README.md)。兼容性见 [`COMPATIBILITY.md`](./COMPATIBILITY.md)。
