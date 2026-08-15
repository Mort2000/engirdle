# api/

后端契约层：

- `client.ts`：`/api/*` 请求封装（fetch + 错误语义）（后续阶段填充）。
- `types.generated.ts`：`npm run gen:api` 生成的 OpenAPI 类型，禁止手改。
- `hooks/`：TanStack Query 数据 hooks（含任务详情 SSE 事件驱动的缓存失效）（后续阶段填充）。

## 契约生成

`npm run gen:api` 一步完成两端：

1. `gen:openapi`：回到 `apps/pc` 运行 `uv run python scripts/export_openapi.py`，
   用 TestClient 拉取 `/openapi.json`（不启动服务器）写入本目录上级的
   `openapi.json`（已 gitignore 的中间产物）；
2. `openapi-typescript ./openapi.json -o src/api/types.generated.ts` 生成类型并提交。

后端 `/api/*` 契约变更后必须重新生成并提交 `types.generated.ts`；
CI 会重新生成并比对，不一致即失败（设计 §11）。
