# Dictionary pack v1 兼容性

## v1.0

- 消费者接受已实现的 `1.x` 次版本，忽略未知可选 manifest 字段，拒绝其他主版本。
- `dictionary_id`、正式来源集合、必需包路径、数据库 schema version 和规范化版本是不可忽略语义；改变任一项需要新产品 ID、revision 或契约主版本。
- 同一 `dictionary_id` / `revision` 的字节不可覆盖；内容变化必须增加 revision。
- Catalog 中的 dictionary 字段是 catalog v1 的可选扩展，旧消费者可以忽略，文章下载语义不受影响。
