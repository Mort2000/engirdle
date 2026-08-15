import { useParams } from "react-router"

import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

export function VoiceBatchPage() {
  const { batchId } = useParams()

  return (
    <PagePlaceholder
      title="候选试听"
      description="锚点候选试听与确认（对应 voice_batch.html，后续阶段接入）。"
      breadcrumbs={[
        { label: "工作台", to: "/" },
        { label: "声音配置", to: "/voices" },
        { label: batchId ? `批次 ${batchId.slice(0, 8)}` : "批次…" },
      ]}
    />
  )
}
