/**
 * `/api/*` 请求封装（设计 §5：api/client.ts）。
 *
 * 管理端与后端同源（生产期 FastAPI 托管、开发期 Vite 代理），无需
 * baseURL 与鉴权头；这里统一 JSON 语义与错误形状，让调用方以
 * `ApiError` 拿到后端 `{"detail": ...}` 的可读信息。
 */

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, detail: string) {
    super(detail)
    this.name = "ApiError"
    this.status = status
  }
}

async function decodeError(response: Response): Promise<ApiError> {
  let detail = `${response.status} ${response.statusText}`.trim()
  try {
    const body: unknown = await response.json()
    if (body && typeof body === "object" && "detail" in body) {
      const raw = (body as { detail: unknown }).detail
      if (typeof raw === "string" && raw.length > 0) {
        detail = raw
      }
    }
  } catch {
    // 非 JSON 错误体（如静态资源 404）保留状态行文案。
  }
  return new ApiError(response.status, detail)
}

/** 发起 JSON 请求并解析响应；非 2xx 抛出 ApiError。 */
export async function apiFetch<T>(
  path: string,
  init?: RequestInit,
): Promise<T> {
  const { headers, ...rest } = init ?? {}
  const response = await fetch(path, {
    ...rest,
    headers: {
      ...(rest.body !== undefined ? { "Content-Type": "application/json" } : {}),
      ...headers,
    },
  })
  if (!response.ok) {
    throw await decodeError(response)
  }
  if (response.status === 204) {
    return undefined as T
  }
  return (await response.json()) as T
}
