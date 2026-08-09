# Dictionary pack v2 兼容性

## v2.0

- 消费者接受已实现的 `2.x` 次版本，拒绝其他主版本。
- v2 与 v1 数据库语义不兼容；新版客户端启动恢复时定向清理已登记的 v1 安装，不迁移或重解释旧包。
- 清理仅限应用词典根目录下、由安装记录精确指向的 v1 revision；生词本快照不受影响。
- 同一 `dictionary_id` / `revision` 的字节不可覆盖；内容变化必须增加 revision。
- `dictionary_id`、正式来源集合、数据库 schema version、规范化版本或 ILI 对齐规则发生语义变化时，必须增加契约主版本或资源 revision。
