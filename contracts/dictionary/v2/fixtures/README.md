# Dictionary v2 fixtures

本目录保存 PC 与 Flutter 共同读取的 manifest 黄金样例。

| Fixture | 预期 | 首个必须命中的原因 |
|---|---|---|
| `valid/minimal.json` | 接受 | v2 manifest 及两个正式来源均合法 |
| `invalid/unsupported-major.json` | 拒绝 | `format_version` 不是 `2.x` |
| `invalid/wrong-source-set.json` | 拒绝 | 正式来源集合包含未批准的来源 |

SQLite schema、ILI 对齐 provenance、外键和 ZIP 安全规则由 PC 构建器与 Flutter
安装器的契约测试动态构造；这里不保存容易与 schema 漂移的二进制数据库副本。
