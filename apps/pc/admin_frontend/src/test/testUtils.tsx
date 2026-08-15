/**
 * 测试公共设施：Provider 包装渲染 + fetch/EventSource 桩。
 */

import { render } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { MemoryRouter, Route, Routes } from "react-router"
import { vi, type Mock } from "vitest"

export function createTestQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: { retry: false },
      mutations: { retry: false },
    },
  })
}

interface RenderOptions {
  queryClient?: QueryClient
  /** 初始地址（MemoryRouter initialEntries）。 */
  route?: string
  /** 路由匹配模式（如 /jobs/:jobId），缺省为通配。 */
  path?: string
}

export function renderWithProviders(
  ui: ReactNode,
  options?: RenderOptions,
): ReturnType<typeof render> {
  const queryClient = options?.queryClient ?? createTestQueryClient()
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[options?.route ?? "/"]}>
        <Routes>
          <Route path={options?.path ?? "*"} element={ui} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

/** 按路径前缀分发的 fetch 桩请求描述。 */
export interface MockApiRequest {
  url: string
  method: string
  init?: RequestInit
}

type RouteHandler = (request: MockApiRequest) => unknown

/** 最小 Response 形状（避免 undici 定时器与 fake timers 纠缠）。 */
function jsonResponse(body: unknown, status = 200): unknown {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: status === 404 ? "Not Found" : "OK",
    json: async () => body,
  }
}

/**
 * 按路径前缀分发的 fetch 桩：`mockApiFetch({ "/api/jobs": () => [...] })`。
 * 未命中路径返回 404；处理器返回值原样作为 JSON 体。路径更具体的路由优先。
 */
export function mockApiFetch(routes: Record<string, RouteHandler>): Mock {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString()
    const method = (init?.method ?? "GET").toUpperCase()
    const request: MockApiRequest = { url, method, init }
    for (const [prefix, handler] of Object.entries(routes)) {
      if (url === prefix || url.startsWith(`${prefix}?`) || url.startsWith(`${prefix}/`)) {
        // 更具体的路由（路径更长）优先：避免 /api/jobs 抢占 /api/jobs/x。
        const moreSpecific = Object.keys(routes).some(
          (other) => other !== prefix && other.startsWith(`${prefix}/`) && url.startsWith(other),
        )
        if (moreSpecific) {
          continue
        }
        return jsonResponse(handler(request))
      }
    }
    return jsonResponse({ detail: `no route for ${method} ${url}` }, 404)
  })
  vi.stubGlobal("fetch", fetchMock)
  return fetchMock
}

type EventListener = (event: Event) => void

/** 可控的 EventSource 桩：手动触发 open/error 与具名事件。 */
export class FakeEventSource {
  static instances: FakeEventSource[] = []
  readonly url: string
  readyState = 0
  closed = false
  private readonly listeners = new Map<string, Set<EventListener>>()

  constructor(url: string) {
    this.url = url
    FakeEventSource.instances.push(this)
  }

  static reset(): void {
    FakeEventSource.instances = []
  }

  static last(): FakeEventSource {
    const last = FakeEventSource.instances.at(-1)
    if (!last) {
      throw new Error("没有已创建的 FakeEventSource 实例")
    }
    return last
  }

  addEventListener(type: string, listener: EventListener): void {
    const set = this.listeners.get(type) ?? new Set()
    set.add(listener)
    this.listeners.set(type, set)
  }

  removeEventListener(type: string, listener: EventListener): void {
    this.listeners.get(type)?.delete(listener)
  }

  close(): void {
    this.closed = true
    this.readyState = 2
  }

  emit(type: string, data: unknown): void {
    const event = new MessageEvent<string>(type, {
      data: typeof data === "string" ? data : JSON.stringify(data),
    })
    this.listeners.get(type)?.forEach((listener) => listener(event))
  }

  fireError(): void {
    this.listeners.get("error")?.forEach((listener) => listener(new Event("error")))
  }

  fireOpen(): void {
    this.readyState = 1
    this.listeners.get("open")?.forEach((listener) => listener(new Event("open")))
  }
}

export function stubEventSource(): void {
  vi.stubGlobal("EventSource", FakeEventSource)
}
