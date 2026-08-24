# Translation v1

PC 与 mobile 共享的 LLM 文章翻译协议。两个实现（PC Python、mobile Dart）各自维护运行时代码，但必须通过本目录同一批 fixtures：协议漂移会在双端契约测试中直接暴露，而不是等到译文错位。设计基线见 `.scratch/mvp/translation_module_design.md` 与 `.scratch/mobile_lightweight_readpack_translation_design.md` §8。

## 固定内容

- `system_prompt.txt`：system 消息的**逐字节**文本。实现不得改写、增删空白或本地化。
- `protocol.json`：机器可读的协议常量与规则——`prompt_version`、thinking/reasoning 配置、目标语言、40,000 字符译文上限、占位符形状与验证规则、请求序列与响应校验规则。实现必须与这些值一致（PC 测试断言相等，mobile 同理）。

## 请求协议

1. **System 消息**：`system_prompt.txt` 原文。
2. **Source context（第一条 user 消息）**：不含代码的完整文章上下文（`schema/source-context.schema.json`）：标题、可选作者、按文章顺序的每个文本块句子组、每张表全部可见 cell、代码块只出现 `{"type": "omitted_code_block"}` 标记，分隔线完全省略。上下文对受保护 run 做全文档一次编号的占位符替换。
3. **Unit 请求**：按文章顺序串行，每个 unit 一条 user 消息，编号只覆盖该 unit 自身的受保护字面量：
   - sentence batch（`schema/sentence-array.schema.json`）：一个文本块的全部句子，纯 JSON 字符串数组；
   - table（`schema/table-object.schema.json`）：整表一个对象，`block_id`、`columns`、`alignments`、`header`、`rows` 的 cell 携带 `cell_id` + `text`；整表翻译，永不按 cell 拆分。
4. **完整历史重放**：每次请求重放 system + source context + 此前全部已接受的 user/assistant 轮次；不滑窗、不摘要、不自动换模型，上下文超限明确失败。

## 占位符

行内 code 与"显示文字等于 URI"的 autolink 永不以原文进入请求：出现即按出现顺序替换为 `‰N‰`（U+2030 哨兵 + ASCII 数字）。验证是槽位敏感的——每个占位符必须在其被保护的原槽位恰好出现一次，全局出现但槽位错换同样拒绝；前导零、非 ASCII 数字、凭空索引等非规范拼写按协议错误处理。恢复只做单趟完整拼写匹配。

## 响应协议

- sentence：等长纯 JSON 字符串数组，每项非空；
- table：与请求同形状对象，`cell_id` 同位同值，cell 文本非空；
- 允许剥离前导 BOM 与**一层** markdown code fence；其余包裹（prose、对象包装）一律协议错误；
- 校验通过的原始 assistant `content` 与类型化结果在同一事务写入 journal；不保存 reasoning content；
- 失败响应不进入历史；瞬态错误有限重试。

## Fixtures

- `fixtures/golden/article.json`：小型类型化文章（标题句、含行内 code 与 autolink 的段落、表格、代码块、分隔线）。
- `fixtures/golden/expected_messages.json`：该文章投影出的完整消息序列——system 原文、source context 字符串与每个 unit 的请求字符串（含占位符编号）。实现必须逐字节重现。
- `fixtures/responses/valid/`：必须通过解析与形状/占位符校验的响应。
- `fixtures/responses/invalid/`：必须被拒绝的响应（错长、空项、加 cell、prose 包裹、损坏占位符）。每个文件对应 golden 文章的哪个 unit 见 `fixtures/README.md`。

HTTP SDK、超时、退避和 WorkManager 调度不属于本契约；错误分类（鉴权/余额/瞬态/上下文）在各实现内保持语义一致。
