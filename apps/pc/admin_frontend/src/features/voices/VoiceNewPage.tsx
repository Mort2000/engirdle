import { PagePlaceholder } from "@/components/layout/PagePlaceholder"

export function VoiceNewPage() {
  return (
    <PagePlaceholder
      title="新建锚点候选"
      description="选择英文说话人并生成 CustomVoice 锚点候选（对应 voice_new.html，后续阶段接入）。"
      breadcrumbs={[
        { label: "工作台", to: "/" },
        { label: "声音配置", to: "/voices" },
        { label: "新建候选" },
      ]}
    />
  )
}
