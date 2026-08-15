/**
 * 删除文章的 AlertDialog（设计 §6.1：破坏性操作二次确认）。
 *
 * 保留既有语义：必须输入文章 ID 才能确认，DELETE 请求携带
 * confirmation 查询参数。由结构确认页与工作台文章库共用。
 */

import { useState } from "react"

import { useDeleteArticleMutation } from "@/api/hooks/articles"
import { Button } from "@/components/ui/button"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Input } from "@/components/ui/input"
import { toast } from "sonner"

interface DeleteArticleDialogProps {
  articleId: string
  /** 删除成功后的回调（结构页跳工作台；工作台留在原地刷新）。 */
  onDeleted?: () => void
  /** 触发按钮文案（各入口可自定义）。 */
  triggerLabel?: string
  triggerVariant?: "destructive" | "outline" | "ghost"
  triggerSize?: "default" | "sm" | "xs"
  triggerClassName?: string
  /** 触发按钮附加 title/aria-label（图标触发器等场景）。 */
  triggerTitle?: string
}

export function DeleteArticleDialog({
  articleId,
  onDeleted,
  triggerLabel = "删除本地文章",
  triggerVariant = "destructive",
  triggerSize = "default",
  triggerClassName,
  triggerTitle,
}: DeleteArticleDialogProps) {
  const [confirmation, setConfirmation] = useState("")
  const deleteMutation = useDeleteArticleMutation()

  const onDelete = async () => {
    if (confirmation !== articleId) {
      return
    }
    try {
      await deleteMutation.mutateAsync({ articleId, confirmation })
      toast.success(`文章 ${articleId} 已移入回收站`)
      setConfirmation("")
      onDeleted?.()
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "删除失败，请重试",
      )
    }
  }

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button
          variant={triggerVariant}
          size={triggerSize}
          className={triggerClassName}
          title={triggerTitle ?? triggerLabel}
          aria-label={triggerTitle ?? triggerLabel}
        >
          {triggerLabel}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>删除本地文章</AlertDialogTitle>
          <AlertDialogDescription>
            此操作将 {articleId} 的源文件、工作文件和制品移入可恢复
            trash。输入文章 ID 以确认。
          </AlertDialogDescription>
        </AlertDialogHeader>
        <Input
          value={confirmation}
          onChange={(event) => setConfirmation(event.target.value)}
          placeholder={articleId}
          aria-label="输入文章 ID 以确认"
        />
        <AlertDialogFooter>
          <AlertDialogCancel>取消</AlertDialogCancel>
          <AlertDialogAction
            disabled={confirmation !== articleId || deleteMutation.isPending}
            onClick={onDelete}
          >
            确认删除
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
