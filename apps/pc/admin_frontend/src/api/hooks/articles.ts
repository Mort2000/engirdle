/**
 * 文章域 TanStack Query hooks。
 *
 * 查询键按 ["articles", ...] 分层；结构与结构报告的失效共用该前缀。
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"

import {
  approveArticleRevision,
  createArticle,
  createArticleRevision,
  deleteArticle,
  editStructure,
  getArticle,
  listArticles,
  rebuildArticleRevision,
  type CreateArticleInput,
} from "@/api/articles"
import type { EditStructurePayload } from "@/features/articles/editedBlockSchema"

export const articlesKeys = {
  root: ["articles"] as const,
  detail: (articleId: string, revision: number) =>
    [...articlesKeys.root, "detail", articleId, revision] as const,
  latestList: () => [...articlesKeys.root, "latest-list"] as const,
}

/** 修订详情（结构确认页主数据）。 */
export function useArticle(articleId: string | undefined, revision: number | undefined) {
  return useQuery({
    queryKey: articlesKeys.detail(articleId ?? "", revision ?? -1),
    queryFn: () => getArticle(articleId as string, revision as number),
    enabled: articleId !== undefined && articleId.length > 0 && revision !== undefined,
  })
}

/** 各文章最新修订：新修订录入页据此预填表单（含 raw_text）。 */
export function useLatestArticle(articleId: string | undefined) {
  return useQuery({
    queryKey: articlesKeys.latestList(),
    queryFn: listArticles,
    enabled: articleId !== undefined && articleId.length > 0,
    select: (revisions) =>
      revisions.find((revision) => revision.article_id === articleId),
  })
}

function useInvalidateArticles() {
  const queryClient = useQueryClient()
  // ["articles"] 前缀同时级联结构报告（["articles","structure-report",...]）。
  return () => {
    void queryClient.invalidateQueries({ queryKey: articlesKeys.root })
  }
}

export function useCreateArticleMutation() {
  const invalidate = useInvalidateArticles()
  return useMutation({ mutationFn: (input: CreateArticleInput) => createArticle(input), onSuccess: invalidate })
}

export function useCreateArticleRevisionMutation(articleId: string | undefined) {
  const invalidate = useInvalidateArticles()
  return useMutation({
    mutationFn: (input: CreateArticleInput) =>
      createArticleRevision(articleId as string, input),
    onSuccess: invalidate,
  })
}

export function useDeleteArticleMutation() {
  const invalidate = useInvalidateArticles()
  return useMutation({
    mutationFn: (input: { articleId: string; confirmation: string }) =>
      deleteArticle(input.articleId, input.confirmation),
    onSuccess: invalidate,
  })
}

/** 保存结构化编辑：成功后失效修订详情与结构报告（树/计数随之刷新）。 */
export function useEditStructureMutation(articleId: string, revision: number) {
  const invalidate = useInvalidateArticles()
  return useMutation({
    mutationFn: (payload: EditStructurePayload) =>
      editStructure(articleId, revision, payload),
    onSuccess: invalidate,
  })
}

/** 冻结并创建任务：调用方跳转任务详情页。 */
export function useApproveRevisionMutation(articleId: string, revision: number) {
  const invalidate = useInvalidateArticles()
  return useMutation({
    mutationFn: () => approveArticleRevision(articleId, revision),
    onSuccess: invalidate,
  })
}

export function useRebuildRevisionMutation(articleId: string, revision: number) {
  const invalidate = useInvalidateArticles()
  return useMutation({
    mutationFn: () => rebuildArticleRevision(articleId, revision),
    onSuccess: invalidate,
  })
}
