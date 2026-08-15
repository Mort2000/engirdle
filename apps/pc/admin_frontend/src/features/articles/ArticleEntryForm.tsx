/**
 * 文章录入表单（设计 §5.1 /articles/new 与 /articles/:id/new-revision
 * 共用）：标题、英文 Markdown（CodeMirror 编辑器）、作者、来源、许可。
 *
 * - react-hook-form + zod 客户端校验，约束与后端 CreateArticleRequest
 *   同构（title/body 必填，512 字符上限，source_url 须为 http(s)）；
 * - 正文录入用 components/markdown/MarkdownEditor（GFM 高亮 + 富文本
 *   粘贴转换 + 字数/句数统计）；
 * - 提交成功由页面导航到修订的结构确认页（§7.3）。
 */

import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { useState } from "react"
import { Link, useNavigate } from "react-router"
import { toast } from "sonner"
import { z } from "zod"

import type { CreateArticleInput, RevisionPayload } from "@/api/articles"
import { Button } from "@/components/ui/button"
import {
  Form,
  FormControl,
  FormField,
  FormItem,
  FormLabel,
  FormMessage,
} from "@/components/ui/form"
import { Input } from "@/components/ui/input"
import { MarkdownEditor } from "@/components/markdown/MarkdownEditor"

const articleFormSchema = z.object({
  title: z
    .string()
    .trim()
    .min(1, "请输入标题")
    .max(512, "标题最长 512 字符"),
  body: z.string().min(1, "请输入英文 Markdown 正文"),
  author: z.string().max(512, "作者最长 512 字符"),
  source_name: z.string().max(512, "来源名称最长 512 字符"),
  source_url: z
    .string()
    .refine(
      (value) =>
        value === "" ||
        (/^https?:\/\//.test(value) && URL.canParse(value)),
      "来源 URL 必须是合法的 http(s) 地址",
    ),
  license_name: z
    .string()
    .trim()
    .min(1, "请输入许可说明")
    .max(512, "许可说明最长 512 字符"),
})

export type ArticleFormValues = z.infer<typeof articleFormSchema>

export interface ArticleFormDefaults {
  title: string
  body: string
  author: string
  source_name: string
  source_url: string
  license_name: string
}

export interface ArticleEntryFormProps {
  defaults: ArticleFormDefaults
  submitLabel: string
  /** 页面注入的提交动作（创建文章或创建新修订）。 */
  onSubmitInput: (input: CreateArticleInput) => Promise<RevisionPayload>
  /** 取消返回地址。 */
  cancelTo: string
}

export function ArticleEntryForm({
  defaults,
  submitLabel,
  onSubmitInput,
  cancelTo,
}: ArticleEntryFormProps) {
  const [submitting, setSubmitting] = useState(false)
  const navigate = useNavigate()
  const form = useForm<ArticleFormValues>({
    resolver: zodResolver(articleFormSchema),
    defaultValues: defaults,
  })

  const onSubmit = form.handleSubmit(async (values) => {
    setSubmitting(true)
    try {
      const revision = await onSubmitInput({
        title: values.title,
        body: values.body,
        author: values.author.trim() || null,
        source_name: values.source_name.trim() || null,
        source_url: values.source_url.trim() || null,
        license_name: values.license_name,
      })
      toast.success(`已保存修订 ${revision.revision}，请确认结构`)
      // 成功后跳转该修订的结构确认页（§7.3 衔接）。
      navigate(`/articles/${revision.article_id}/revisions/${revision.revision}`)
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "保存失败，请重试",
      )
      setSubmitting(false)
    }
  })

  return (
    <Form {...form}>
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <FormField
          control={form.control}
          name="title"
          render={({ field }) => (
            <FormItem>
              <FormLabel>标题</FormLabel>
              <FormControl>
                <Input
                  {...field}
                  placeholder="Article title"
                  autoFocus={defaults.title === ""}
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="body"
          render={({ field }) => (
            <FormItem>
              <FormLabel>英文 Markdown</FormLabel>
              <FormControl>
                <MarkdownEditor
                  value={field.value}
                  onChange={field.onChange}
                  label="英文 Markdown"
                  placeholder="Paste Markdown: headings, paragraphs, lists, quotes, tables and fenced code blocks…"
                />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="author"
            render={({ field }) => (
              <FormItem>
                <FormLabel>作者（可选）</FormLabel>
                <FormControl>
                  <Input {...field} placeholder="Original author" />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="source_name"
            render={({ field }) => (
              <FormItem>
                <FormLabel>来源名称（可选）</FormLabel>
                <FormControl>
                  <Input {...field} placeholder="Publication or site name" />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="source_url"
            render={({ field }) => (
              <FormItem>
                <FormLabel>来源 URL（可选）</FormLabel>
                <FormControl>
                  <Input
                    {...field}
                    type="url"
                    placeholder="https://example.com/article"
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="license_name"
            render={({ field }) => (
              <FormItem>
                <FormLabel>许可说明</FormLabel>
                <FormControl>
                  <Input {...field} placeholder="CC BY 4.0" />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>

        <div className="flex items-center gap-3 pt-2">
          <Button type="submit" disabled={submitting}>
            {submitting ? "保存中…" : submitLabel}
          </Button>
          <Button asChild variant="ghost" disabled={submitting}>
            <Link to={cancelTo}>取消</Link>
          </Button>
        </div>
      </form>
    </Form>
  )
}
