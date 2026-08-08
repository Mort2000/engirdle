# PC 端 LLM 翻译模块设计（实现版）

> 状态：已实现并通过对抗性评审修订
> 对应需求：`mvp_design.md` §4.4、§9.3、§10、§11.2
> 更新：2026-08-08

`apps/pc` 翻译模块的最终实现设计，作为 `mvp_design.md` §4.4 的实现基线。与 §4.4 原文的差异
（取消首轮确认、位置数组 schema）为用户确认的简化，见文末对照表。

## 1. 范围与原则
- DeepSeek 官方 API（OpenAI 兼容）为唯一生产翻译路径；生产代码无桩，确定性 fake 仅在 `tests/`。
- `DEEPSEEK_API_KEY` 仅用于生产流程或一次性手工临时验证；不写 live pytest、不固化、不进 CI。
- `.env` 已加入 `.gitignore`（评审 C1 修复）。

## 2. 模块结构（`src/engirdle_pc/modules/translation/`）
- `application/ports.py`：`TranslationAdapter` 协议（`begin/translate_block/verify_access` + 身份属性）、`TranslationBatch`、`SentenceTranslation`、`TranslationStore`
- `application/service.py`：`TranslationService`，第二道 ID 集合校验 + 落库 + 透传 `verify_access`
- `application/dto.py`：Pydantic `TranslationList(RootModel[list[str]])`、`PROMPT_VERSION`、`THINKING_MODE`/`REASONING_EFFORT` 常量、prompt 构造器、BOM/围栏剥离
- `infrastructure/deepseek_adapter.py`：`DeepSeekTranslationAdapter`、`load_deepseek_api_key`、`build_deepseek_adapter`
- `infrastructure/chat_client.py`：`DeepSeekApiClient` 端口、`OpenAIDeepSeekApiClient`（openai SDK）、`classify_api_error`
- `infrastructure/session_journal.py`：`TranslationSessionJournal`（按 checkpoint 持久化已接受块译文）
- `infrastructure/deepseek_errors.py`：类型化错误 + `is_transient`

## 3. 翻译协议（简化版，偏离 §4.4.1）
取消"完整原文首轮 LLM 确认"；交互为最简位置数组：
1. `begin(revision)`（不触网）：生成 `checkpoint_id`，创建空 journal。
2. `translate_block`：每次完整重放 `messages = [system, user=完整原文, …(user 块ᵢ 源句数组, assistant 块ᵢ 译数组)…, user=当前块源句数组]`；当前块发 `["s1",…]`，模型回同序等长 `["译1",…]`，按位置回填 `sentence_id`。
3. 不使用 `response_format: json_object`（裸数组非 object）；system 强约束"仅返回 JSON 数组、无 prose/无 fence"；解析容忍并剥离 BOM 与 ```json 围栏（已用真实 API 验证可靠）。

完整历史不滑窗、不摘要、不降级；上下文超限以 `TranslationContextLimitError` 明确失败。

## 4. 校验与持久化（§4.4.2）
每段响应须为同序等长的非空字符串数组，否则抛 `TranslationProtocolError` 且**不写入历史**（校验先于持久化）。
`TranslationService` 再做一次 sentence ID 集合校验。`request_id` 关联；用量（prompt/completion/reasoning tokens）结构化日志，不含正文/译文/reasoning。

## 5. 会话与恢复（§4.4.1/§4.4.2）
- 逻辑会话由 PC 端保存并每次完整重放；journal 落盘到 `workspace/translation_sessions/<id>.json`。
- 完整原文与各块源句由不可变 `ArticleRevision` 确定性重建，journal 只存已接受译文数组。
- resume 复用 `checkpoint_id`，跨进程可从 journal 重建；校验失败响应不进入 journal。

## 6. 客户端、错误与重试
- `OpenAIDeepSeekApiClient` 包裹官方 `openai` SDK（`base_url` 固定官方），`extra_body={"thinking":{"type":"enabled"},"reasoning_effort":"max"}`；`verify_access` 用 `models.list()`。
- 适配器依赖可注入 `DeepSeekApiClient` 端口；契约测试注入 `FakeDeepSeekApiClient`。
- `openai.APIError` → 纯函数 `classify_api_error` 映射为类型化错误（401/403、402、429、5xx/连接、超时、400/413+上下文标记、其余）。
- 瞬态错误（RateLimit/Server/Timeout）**与瞬态协议错误**（长度不符/被围栏/对象包裹/空响应）在单次请求内有限重试 + 指数退避（默认 3 次）；鉴权/配额/上下文超限/配置错误立即抛出，由 worker 从 checkpoint 重试（不压缩上下文、不换模型）。
- `verify_access()` 既校验 key 又断言 `model ∈ models.list()`（防模型名拼错"启动健康但每段必败"）。
- journal 读取对损坏/缺字段 JSON 抛 `TranslationProtocolError`（非裸 `JSONDecodeError`）；resume 校验 `source_sha256`/`prompt_version`，防 checkpoint 复用或升级后的陈旧历史。
- 真实客户端构造即拒绝非官方 endpoint（与工厂双重校验，§10）。

## 7. 安全与隐私（§10）
- API Key 仅从 `DEEPSEEK_API_KEY` 注入，不写入 `Settings`/SQLite/manifest/目录/日志；`.env` 已 gitignore。
- 生产只允许官方 endpoint；`build_deepseek_adapter` 与 `OpenAIDeepSeekApiClient` 双重断言。
- assistant 历史只存 `content`，**绝不**保存/重放/记录 `reasoning_content`。
- 原文置于结构化数据边界，system 声明其为翻译素材，纵含命令也不执行（实测注入句被忠实翻译为文本，未执行）。

## 8. 配置与入口
`Settings`：`deepseek_endpoint`、`deepseek_model`（`deepseek-v4-flash`）、`deepseek_request_timeout_seconds`、`deepseek_max_retries`（非 secret；thinking/reasoning_effort 为固定基线常量，不在 Settings）。`Container.build(..., deepseek_api_key=...)` 默认构建真实适配器（构造不联网）。worker 入口（daemon + `worker-once`）：缺 key 或 `verify_access()` 失败 → 结构化日志 + `sys.exit(1)`；admin/check/publisher 不需 key。

## 9. 测试策略（§11.2）
`tests/integration/translation/`：适配器契约（`begin` 不触网、逐段翻译、每轮完整历史重放含源上下文断言、3 块累积 2 个 assistant 轮次、长度/非数组/空成员/非 JSON 拒绝且不污染历史、协议错误重试、瞬态重试不压缩上下文、缺 key/缺 journal 报错、跨实例 resume、journal 陈旧/损坏→类型化错误、位置回填 ID、`classify_api_error` 与真实 `_map_api_error` 映射、工厂拒绝非官方 endpoint、真实客户端拒绝非官方 endpoint、`verify_access` 拒绝未上架模型、围栏/BOM 响应解析）；`test_session_journal.py`；`test_worker_fail_fast.py`（缺 key / 鉴权失败 → `SystemExit(1)`）。`tests/translation_fake.py` + 根 `conftest.py` 提供确定性 fake。真实 API 仅一次性手工验证（临时脚本，不入仓/CI）。

## 10. 与 §4.4 原文的差异
| §4.4 原文 | 实现 | 原因 |
|---|---|---|
| 完整原文首轮 LLM 确认对象 | 取消，直接逐段 | 用户简化 |
| 响应 `{translations:[{sentence_id,text}]}` + ID 集合校验 | 裸位置数组 + 长度/非空校验，按位置回填 ID | 用户简化 schema |
| `response_format: json_object` | 不使用（裸数组非 object） | 适配裸数组输出 |
| DeepSeek Chat Completions 客户端 | 官方 `openai` SDK | 不重复造轮子 |
| 协议错误立即失败 | 协议错误也有限重试（评审 H2） | 应对模型偶发格式抖动 |
