import { useParams } from "react-router"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

export function JobDetailPage() {
  const { jobId } = useParams()

  return (
    <PagePlaceholder
      title="任务详情"
      description="阶段步进、进度、审阅与发布（对应 job.html，后续阶段接入）。"
      breadcrumbs={[
        { label: "工作台", to: "/" },
        { label: "任务", to: "/jobs" },
        { label: jobId ?? "…" },
      ]}
    />
  )
}
