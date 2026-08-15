# api/

后端契约层：

- `client.ts`：`/api/*` 请求封装（fetch + 错误语义：非 2xx 抛 `ApiError`，携带后端 `detail`）。
- `jobs.ts`：任务域载荷类型（后端返回 `dict[str, object]`，OpenAPI 生成类型为 unknown 记录，此处按 app.py 实际组装形状窄化）与请求函数。
- `types.generated.ts`：`npm run gen:api` 生成的 OpenAPI 类型，禁止手改。
- `hooks/`：TanStack Query 数据 hooks 与 SSE 实时流（`useJobStream`：事件驱动缓存更新 + 断连降级 5s 轮询）。

## 契约生成

`npm run gen:api` 一步完成两端：

1. `gen:openapi`：回到 `apps/pc` 运行 `uv run python scripts/export_openapi.py`，
   用 TestClient 拉取 `/openapi.json`（不启动服务器）写入本目录上级的
   `openapi.json`（已 gitignore 的中间产物）；
2. `openapi-typescript ./openapi.json -o src/api/types.generated.ts` 生成类型并提交。

后端 `/api/*` 契约变更后必须重新生成并提交 `types.generated.ts`；
CI 会重新生成并比对，不一致即失败（设计 §11）。
