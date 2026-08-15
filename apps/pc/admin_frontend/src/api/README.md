# api/

后端契约层（后续阶段填充）：

- `client.ts`：`/api/*` 请求封装（fetch + 错误语义）。
- `types.generated.ts`：`npm run gen:api` 由后端 `/openapi.json` 经 openapi-typescript 生成，禁止手改。
- `hooks/`：TanStack Query 数据 hooks（含任务详情 SSE 事件驱动的缓存失效）。
