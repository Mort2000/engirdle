/**
 * 工作台域 TanStack Query hooks（设计 §5：api/hooks/）。
 *
 * summary 为单次往返聚合（§8.5）；发布器启停与重新发布成功后失效
 * summary，使面板状态立即回填。工作台列表刷新策略为聚焦/失效驱动的
 * 轮询（§2.2 非目标 5：SSE 仅覆盖任务详情页）。
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"

import {
  getDashboardSummary,
  republishArtifact,
  startPublisher,
  stopPublisher,
} from "@/api/dashboard"

export const dashboardKeys = {
  root: ["dashboard"] as const,
  summary: () => [...dashboardKeys.root, "summary"] as const,
}

/** 工作台聚合（5s 轮询：近期任务与发布器状态随之刷新）。 */
export function useDashboardSummary(options?: { refetchInterval?: number }) {
  return useQuery({
    queryKey: dashboardKeys.summary(),
    queryFn: getDashboardSummary,
    refetchInterval: options?.refetchInterval,
  })
}

function useInvalidateDashboard() {
  const queryClient = useQueryClient()
  return () => {
    void queryClient.invalidateQueries({ queryKey: dashboardKeys.root })
  }
}

export function useStartPublisherMutation() {
  const invalidate = useInvalidateDashboard()
  return useMutation({ mutationFn: startPublisher, onSuccess: invalidate })
}

export function useStopPublisherMutation() {
  const invalidate = useInvalidateDashboard()
  return useMutation({ mutationFn: stopPublisher, onSuccess: invalidate })
}

/** 重新发布历史制品：同时失效任务/制品相关缓存。 */
export function useRepublishArtifactMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (packageId: string) => republishArtifact(packageId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: dashboardKeys.root })
      void queryClient.invalidateQueries({ queryKey: ["jobs"] })
    },
  })
}
