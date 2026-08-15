// Workflow: Engirdle admin web refactor — implementation + Kimi K3 review closure
// Design baseline: /home/mort/engirdle/.scratch/mvp/admin_web_refactor_design.md
// Review agents run on provider "kimi-coding" / model "k3" (Kimi K3, high reasoning).
// Implementation/fix agents run on the session default model.

const REPO = "/home/mort/engirdle";
const DESIGN = REPO + "/.scratch/mvp/admin_web_refactor_design.md";
const PC = REPO + "/apps/pc";

const implSchema = {
  type: "object",
  properties: {
    status: { type: "string", enum: ["done", "blocked"] },
    summary: { type: "string" },
    baseCommit: { type: "string" },
    commits: { type: "array", items: { type: "string" } },
    verification: {
      type: "object",
      properties: {
        pytest: { type: "string" },
        ruff: { type: "string" },
        mypy: { type: "string" },
        frontend: { type: "string" },
        build: { type: "string" }
      },
      required: ["pytest", "ruff", "mypy", "frontend", "build"],
      additionalProperties: false
    },
    notes: { type: "string" }
  },
  required: ["status", "summary", "baseCommit", "commits", "verification", "notes"],
  additionalProperties: false
};

const reviewSchema = {
  type: "object",
  properties: {
    verdict: { type: "string", enum: ["approve", "request_changes"] },
    findings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          severity: { type: "string", enum: ["blocker", "major", "minor"] },
          file: { type: "string" },
          issue: { type: "string" },
          suggestion: { type: "string" }
        },
        required: ["severity", "file", "issue", "suggestion"],
        additionalProperties: false
      }
    },
    summary: { type: "string" }
  },
  required: ["verdict", "findings", "summary"],
  additionalProperties: false
};

const VERIFY = [
  "- pytest:    cd " + PC + " && uv run pytest -q",
  "- ruff:      cd " + PC + " && uv run ruff check hatch_build.py src tests",
  "- mypy:      cd " + PC + " && uv run mypy src",
  "- frontend:  cd " + PC + "/admin_frontend && npm run lint && npm run typecheck && npm run test",
  "- build:     cd " + PC + "/admin_frontend && npm run build"
].join("\n");

const COMMON = [
  "你是资深全栈工程师，负责实施 Engirdle 管理端 Web 重构（Vite + React SPA 替换 Jinja2 页面）的一个阶段。",
  "",
  "仓库与工程：",
  "- 仓库根: " + REPO + "（git 分支 feat/admin-web-refactor，无 remote，禁止 push）",
  "- Python 包: " + PC + "（uv + Python 3.10；测试基线 222 passed）",
  "- 后端管理端: " + PC + "/src/engirdle_pc/entrypoints/admin_web/（app.py 组装 FastAPI 与约 40 个 /api/* 端点；routes/pages.py 是将被替换的 Jinja 页面路由；view_models.py 服务于 pages.py）",
  "- 前端工程（脚手架阶段后存在）: " + PC + "/admin_frontend（npm 而非 pnpm、package-lock.json 入库、Vite 7 + React 19 + TypeScript strict + Tailwind CSS 4(@tailwindcss/vite) + shadcn/ui 源码入仓 + React Router 7(library 模式) + TanStack Query 5 + react-hook-form + zod；Markdown 编辑用 CodeMirror 6(@uiw/react-codemirror + @lezer/markdown GFM)；富文本粘贴用 turndown + turndown-plugin-gfm；类型生成用 openapi-typescript；测试 Vitest + Testing Library)",
  "- Node 24 与 npm 已在 PATH 中（nvm），npm registry 可达",
  "",
  "设计文档是唯一权威基线，开工前必须通读: " + DESIGN,
  "",
  "流程纪律：",
  "1. 先运行 git log --oneline -12 与 git status 确认起点；若本阶段工作已部分存在（此前中断），验证现状并补齐缺口，不要推倒重来。",
  "2. 记录开工前的 HEAD（git rev-parse HEAD）作为 baseCommit 返回。",
  "3. 严格按本阶段 spec 实施；不越界做后续阶段的活。",
  "4. 实施完毕运行全部适用的验证命令并保证通过（前端工程存在后必须全绿；不适用项填 n/a 并附原因）：",
  VERIFY,
  "5. 只有验证全绿才允许提交；提交信息遵循 Conventional Commits（参考历史: feat(admin): ... / build(admin): ...）；一个阶段允许多个逻辑提交。",
  "6. 禁止：git push、rebase 或修改历史提交、改动 .scratch/mvp/*.md 内容、启动长驻进程（vite dev / uvicorn 服务器）、引入 stub 替代真实实现。",
  "7. 若确实无法让验证通过：把工作树与提交恢复到干净一致的状态（可保留已通过的子集提交），status 填 blocked 并在 notes 说明阻塞点。",
  "",
  "返回 JSON：summary 概述做了什么；commits 列出本阶段提交（hash + message）；verification 各项填 pass(关键数字) / fail(原因) / n/a(原因)；notes 记录偏差与遗留。"
].join("\n");

const RCOMMON = [
  "你是对抗性代码检视者，对 Engirdle 管理端 Web 重构（Vite + React SPA 替换 Jinja2 页面）的一个阶段做独立检视。",
  "",
  "仓库根: " + REPO + "（分支 feat/admin-web-refactor）",
  "设计文档是权威基线，先通读: " + DESIGN,
  "",
  "检视方法：",
  "- 用给出的 diff 范围检查本阶段全部变更（git -C " + REPO + " diff BASE..HEAD 与逐提交 git show）；需要时阅读任意源码、测试与历史代码。",
  "- 可以运行只读验证命令（pytest / ruff / mypy / npm run lint / npm run typecheck / npm run test / npm run build）核实声明，但绝对禁止修改文件、提交、stash、checkout 或以任何方式改变仓库状态。",
  "",
  "检视维度：",
  "1. 设计符合性：逐条对照本阶段 spec 与设计文档相应章节（引用章节号）。",
  "2. 正确性与边界：并发、断连重连、空数据、错误路径、资源泄漏（尤其 SSE/轮询任务生命周期）。",
  "3. 回归：既有约 40 个 /api/* 契约不得破坏，既有测试语义不得倒退。",
  "4. 测试充分性：新增行为必须有测试；删除的测试必须有等价替代。",
  "5. 安全：路径穿越、密钥泄漏、注入。",
  "6. 残留：无 stub/TODO/死代码/过渡代码遗留（本阶段明确要求保留的过渡项除外）。",
  "7. 工程规范：TypeScript strict、mypy strict、Conventional Commits、文档不放大段实现代码。",
  "",
  "裁决规则：",
  "- 无 blocker 且无 major 才 approve；仅剩 minor 时 approve 并在 findings 中列出。",
  "- request_changes 时每条 finding 必须有明确 file 与可执行的 suggestion；拒绝纯风格挑剔与臆测（先读代码核实）。",
  "",
  "输出 JSON（schema）；findings 空数组表示完全通过。"
].join("\n");

const PHASES = [
  {
    id: "scaffold",
    title: "前端脚手架",
    spec: [
      "阶段目标（设计 §4、§5、§6.2、§12 步骤 1）：",
      "1. 先提交设计文档入库：git add " + DESIGN + "，提交信息 docs(admin): add admin web refactor design。",
      "2. 创建 " + PC + "/admin_frontend 前端工程（npm；package-lock.json 入库；.nvmrc 内容为 24）：",
      "   - Vite 7 + React 19 + TypeScript strict（strict 全家桶：noUnusedLocals、noUnusedParameters、noFallthroughCasesInSwitch 等）。",
      "   - vite.config.ts：dev server 代理 /api 与 /openapi.json 到 http://127.0.0.1:8765；构建输出 dist/。",
      "   - Tailwind CSS 4（@tailwindcss/vite 插件，CSS-first 配置）；styles/globals.css 用 @theme 定义 §6.2 token：zinc 中性基调 + indigo 单一强调色、亮/暗双主题 .dark class 策略、中文字体栈 system-ui 与 PingFang SC/Microsoft YaHei、代码用 ui-monospace/JetBrains Mono 栈、rounded-lg、1px 边框低阴影、8pt 间距。",
      "   - shadcn/ui 初始化（components.json；组件源码复制入仓到 src/components/ui/）：button、card、input、textarea、select、dialog、alert-dialog、dropdown-menu、tabs、tooltip、badge、skeleton、progress、table、form、label、sonner(toast)。",
      "   - ESLint 9 flat config（typescript-eslint、react-hooks、react-refresh）；Vitest + Testing Library（jsdom）+ 至少一个冒烟测试。",
      "   - package.json scripts：dev、build、lint、typecheck（tsc --noEmit）、test（vitest run 模式，不得进入 watch）、gen:api（openapi-typescript；后端 openapi.json 导出脚本属下阶段，本阶段先放依赖与脚本占位并在 notes 注明）。",
      "   - 目录骨架按 §5：src/main.tsx、src/router.tsx（React Router 7 library 模式，§5.1 路由表全部为占位页）、src/api/、src/components/{ui,layout,progress,markdown}/、src/features/{dashboard,articles,jobs,voices}/、src/lib/、src/styles/globals.css。",
      "3. 仓库根 .gitignore 追加 admin_frontend/node_modules/ 与 admin_frontend/.build-cache.json（**/dist/ 已被忽略，勿重复；勿把 node_modules 或 dist 提交入库）。",
      "4. 本阶段不改任何 Python 代码；pytest/ruff/mypy 应保持原样全绿（verification 可填 n/a: python untouched，前提是 git 显示无 Python 变更）。"
    ].join("\n")
  },
  {
    id: "api",
    title: "后端 API 增补",
    spec: [
      "阶段目标（设计 §8、§8.5、§12 步骤 2）——只做后端与测试，不做前端页面：",
      "1. 进度派生纯函数（建议 admin_web/progress.py，纯函数 + 集中定义的权重常量）：输入 BuildJob 的 stage/status/heartbeat_at + ProductionCheckpoint（accepted_translation_unit_ids、synthesized_narration_unit_ids）+ ProcessingPlan 单元总数，按 §8.1 权重表输出 progress 对象（stage、stage_index 0-7、percent 保留 1 位小数、done_units、total_units、indeterminate）。单元测试表驱动覆盖：queued/translation/speech/audio/review/packaging/publishing/complete、不确定阶段、终态、空 plan。",
      "2. SSE 端点 GET /api/jobs/{job_id}/events（sse-starlette EventSourceResponse）：JobEventBroker 进程内按 job_id 管理；同一 job 共享一个 1s 轮询任务，订阅归零或终态后停止；SQLite 读取经 anyio.to_thread 走线程池（同步 SQLAlchemy 会话不得阻塞事件循环）；事件协议严格按 §8.2：snapshot（连接/重连首个事件，含与 GET /api/jobs/{id} 相同的详情负载 + progress）、progress（仅变化时）、status（状态迁移全量负载）；事件携带递增 id；15s ping；终态后正常关流。测试用 TestClient 流式读取验证事件序列、断连重连后 snapshot 幂等、多连接共享轮询。",
      "3. GET /api/jobs/{job_id} 与 GET /api/jobs 响应增补派生 progress 字段，与 SSE 负载同构。",
      "4. 新增 GET /api/articles/{article_id}/revisions/{revision}/structure-report：返回解析警告 + 结构树（含派生 translates/narrates 标志）+ 处理计数；逻辑从 routes/pages.py 的 _structure_tree/_processing_counts 平移为 JSON 响应组装（pages.py 本阶段原样保留）。",
      "5. 新增 GET /api/dashboard/summary：articles + jobs + published + artifacts + publisher 状态单次往返聚合（语义对齐 pages.py 现有工作台拼装）。",
      "6. openapi-typescript 接线：新增只读导出脚本（用 TestClient 生成 openapi.json，不启动服务器），打通 admin_frontend 的 npm run gen:api，生成 src/api/types.generated.ts 并提交生成物。",
      "注意：不得破坏既有约 40 个 /api/* 契约与既有测试；响应模型沿用仓库既有 pydantic 风格；mypy strict 全绿；SSE 资源生命周期（连接断开、订阅归零、终态）必须有测试。"
    ].join("\n")
  },
  {
    id: "shell",
    title: "SPA 框架页与托管",
    spec: [
      "阶段目标（设计 §3、§6.1、§9、§12 步骤 3）：",
      "1. FastAPI 托管改造（app.py）：/api/* 优先注册保持不变；/assets/* 挂 hashed 产物 StaticFiles，Cache-Control public, max-age=31536000, immutable；SPA fallback catch-all GET 返回 webui/index.html 且 Cache-Control no-cache（FileResponse，不经模板引擎），必须显式排除 /api 前缀（/api 404 仍是 404 而非 index.html）；旧 Jinja 页面整体移至 /legacy 前缀过渡（页面内静态资源引用保持可用）。",
      "2. webui 目录解析顺序：包内 engirdle_pc/entrypoints/admin_web/webui → 源码树 admin_frontend/dist（开发构建产物）→ 都缺失时启动期抛可读错误（提示从源码构建或安装预构建 wheel）。解析逻辑独立、可单测。",
      "3. 前端框架页：AppShell 布局（可折叠左侧导航：工作台/文章/任务/声音配置；底部主题切换 + 适配器状态徽标占位（stub 验证模式警示））；ThemeProvider 约 30 行自建（localStorage 持久化、.dark class 切换、默认跟随系统）；面包屑 + 页标题 + 右上主操作区骨架；§5.1 全部路由占位页接入 router；支持前端路由深链 fallback。",
      "4. 测试：后端用临时 fixture 目录构造最小 webui 产物（不依赖真实 npm 构建）验证：SPA fallback 缓存头、/api 404 穿透、/legacy 可达、/assets immutable 头、webui 缺失启动错误；前端：AppShell 渲染与导航高亮、ThemeProvider 持久化与切换。",
      "5. 保持全部既有测试绿（/legacy 过渡不得破坏 test_management_pages.py，必要时同步调整其请求路径为 /legacy 并保持断言语义）。"
    ].join("\n")
  },
  {
    id: "jobs",
    title: "任务列表与任务详情页",
    spec: [
      "阶段目标（设计 §5.1 /jobs 与 /jobs/:id、§6.3、§6.4、§8.4、§12 步骤 4）：",
      "1. /jobs 任务列表页：TanStack Query 轮询（5s）+ 状态徽标按 §6.3 色彩语义（queued 灰 / running 蓝含脉动点 / review_required 琥珀 / failed 红 / succeeded 绿）+ 空态与加载骨架。",
      "2. /jobs/:id 任务详情页自上而下按 §8.4：页头（任务 ID、状态徽标、尝试次数、创建/起止时间、重试/发布操作按钮）；进度面板：自建 Stepper（8 阶段：完成=实心、当前=强调色描边、未到=灰；当前阶段标注中文名；横向滚动适配）+ Progress 条（阶段内百分比或 indeterminate 动画）+ 实时计数（如 已合成 127/200 句）+ 心跳相对时间（如 3 秒前）；详情面板：自建 KeyValues 两列 label/value 网格（适配器、translation/speech/audio_encoding 配置快照分组、处理计数）；失败面板（错误码 + 消息 + 重试）；译文审阅（句级三列：原文/机翻/修正，可保存修正）与表格译文审阅（cell 级编辑）；音频审阅（原生 audio 播放器 + 句级播放按钮 + 完整性检查计数）。",
      "3. SSE hook：EventSource 订阅 /api/jobs/{id}/events 驱动页面更新与相关 query 失效；断连自动降级为 5s 轮询 GET /api/jobs/{id}，连接恢复后回到 SSE。",
      "4. 进度计算前端纯函数（lib/，权重与后端 §8.1 一致）驱动 Stepper 与 Progress。",
      "5. 测试：进度纯函数表驱动；SSE hook 用 mock EventSource 验证事件处理、降级与恢复；任务详情页用 mock 数据渲染（含审阅面板交互）；列表页渲染与轮询（fake timers）。",
      "6. 既有 /api/* 契约不动；仅当确有缺口时最小增补并在 notes 说明理由。"
    ].join("\n")
  },
  {
    id: "articles",
    title: "文章录入与结构编辑器",
    spec: [
      "阶段目标（设计 §7、§5.1 /articles/*、§12 步骤 4）：",
      "1. /articles/new 与 /articles/:id/new-revision：CodeMirror 6 编辑器（@uiw/react-codemirror + @lezer/markdown 的 GFM 扩展：表格、删除线、任务列表、自动链接解析与高亮）；编辑器主题基于 §6.2 token 自定义（HighlightStyle/createTheme），随亮暗主题联动；字号行高按正文阅读优化；字数/句数统计；录入表单（既有字段：标题、英文 Markdown、作者、来源、许可等）提交 POST /api/articles，成功后跳转该修订的结构确认页。",
      "2. 富文本粘贴（lib/paste.ts 纯函数 htmlToMarkdown(html): string）：预处理清理 Word/Google Docs 冗余 span/style、批注与 o:p 标签；turndown + turndown-plugin-gfm 转换（表格/删除线/任务列表/标题/列表/链接/行内代码）；img 转 ![alt](src) 保留 alt。编辑器接管 paste 事件：clipboardData 含 text/html 时转换，产物非空则以转换文本替换默认粘贴（可 Ctrl+Z 撤销）并 Toast 提示 富文本已转换为 Markdown；失败或产物为空回退纯文本粘贴；绝不阻塞录入。单测用真实 HTML 样本（Word 导出、Google Docs、网页复制三类）内联 fixture 覆盖。",
      "3. /articles/:id/revisions/:rev 结构确认与结构化编辑器：块列表编辑（重排、句级编辑、拆分、合并、表格 cell 编辑），彻底替换 JSON textarea；zod discriminated union schema 与后端 EditedBlockRequest 同构做客户端校验；页面展示解析警告（琥珀 Alert）+ 结构树（派生 translates/narrates，只读）+ 处理计数（数据来自 structure-report 端点）；保存走既有 PUT /api/articles/{id}/revisions/{rev}/structure 端点；破坏性操作（如删除文章）用 AlertDialog 且保留输入文章 ID 的确认要求。",
      "4. 测试：htmlToMarkdown 三类样本单测；zod schema 判别与校验单测；块编辑器组件测试（编辑/合并/拆分/重排/表格 cell）；CodeMirror 编辑器组件冒烟（渲染与统计）。"
    ].join("\n")
  },
  {
    id: "panels",
    title: "工作台与声音配置页",
    spec: [
      "阶段目标（设计 §5.1 / 与 /voices*、§6.1、§12 步骤 4）：",
      "1. / 工作台：数据来自 GET /api/dashboard/summary 单次往返；文章/任务/发布/制品概览卡片；发布器面板（绑定地址、风险提示、持久化进程状态、启停操作，走既有 publisher API）；近期任务列表（状态徽标 + 链接 /jobs/:id）；删除文章入口用 AlertDialog（输入文章 ID 确认，保留现有语义）。",
      "2. /voices 声音配置总览：当前激活配置（锚点信息、修订历史）、无配置空态引导。",
      "3. /voices/new：speaker 选择、锚点朗读文本、instruct 风格、候选数配置；提交 POST /api/voices/batches 生成候选后跳转批次页。",
      "4. /voices/batches/:id：候选逐个试听（audio 元素 + 既有批次音频端点）、确认激活 / 拒绝交互（走既有 confirm 端点），确认后回声音总览。",
      "5. 页面沿用 AppShell 与卡片式面板；状态徽标按 §6.3；加载/空/错误态完整。",
      "6. 测试：工作台 summary 渲染与发布器面板交互（mock fetch/query）；声音三页渲染与关键交互（mock）；AlertDialog 输入门控测试。"
    ].join("\n")
  },
  {
    id: "build",
    title: "构建与打包集成",
    spec: [
      "阶段目标（设计 §10、§12 步骤 5、风险 R1/R2/R3）：",
      "1. 扩展 " + PC + "/hatch_build.py（保留既有 contracts 逻辑）：",
      "   - wheel 目标：npm 经 shutil.which 解析（Windows 兼容 npm.cmd）；未找到时报含 Node ≥ 22 安装指引的可读错误；ENGIRDLE_SKIP_WEB_BUILD=1 时要求 admin_frontend/dist 已存在否则报错（无网络 CI 逃生门）；源码哈希清单 admin_frontend/.build-cache.json（不入库）记录输入文件哈希，未变更则跳过 npm 直接复用 dist；否则 npm ci（按 lockfile）+ npm run build，然后 force_include 注入 engirdle_pc/entrypoints/admin_web/webui/。",
      "   - sdist 目标：包含 admin_frontend 源码（package.json、package-lock.json、src/、vite.config.ts、tsconfig、eslint 配置、index.html、.nvmrc）。",
      "2. 验证构建链路并写进 notes 的证据：cd " + PC + " && uv build 产出 wheel + sdist；解包检查 wheel 内含 engirdle_pc/entrypoints/admin_web/webui/index.html 与 assets；把 sdist 解包到临时目录二次 uv build（不设 ENGIRDLE_SKIP_WEB_BUILD，证明 sdist→wheel 链路可二次构建）；再跑一次 uv build 验证 .build-cache.json 命中缓存跳过 npm（用构建输出判断），验证后删除临时目录、勿把 .build-cache.json 提交入库。",
      "3. 更新 " + PC + "/README.md：质量检查一节加入 npm run lint / npm run typecheck / npm run test 与 uv build 语义（wheel 预置产物安装期不需要 Node；源码与 sdist 构建需 Node ≥ 22 + .nvmrc；ENGIRDLE_SKIP_WEB_BUILD 逃生门；uv sync 首次会触发前端构建、哈希缓存后续跳过）。文档遵守仓库规范：流程用 PlantUML、不放大段实现代码。",
      "4. 全部验证命令保持全绿（pytest 不触发构建钩子；如发现 uv sync 因钩子变慢属预期，在 notes 说明）。"
    ].join("\n")
  },
  {
    id: "cleanup",
    title: "页面层退役清理",
    spec: [
      "阶段目标（设计 §1、§12 步骤 6、风险 R9）：",
      "1. 删除 routes/pages.py、templates/、static/、view_models.py、pyproject 中 jinja2 依赖（uv lock 同步更新）、/legacy 挂载与全部过渡代码；SPA 成为唯一页面层；app.py 移除 Jinja 模板环境、/static 挂载与 pages 路由引用。",
      "2. test_management_pages.py 迁移：页面表单流断言改为 API 级测试（既有 API 测试已覆盖大部分，确保录入→结构确认→审阅→发布关键流仍有等价覆盖）；删除的每个测试必须有等价替代或在 notes 说明为何不再适用；前端已有组件测试的语义不重复后端测试。",
      "3. 全量验证矩阵全绿 + uv build 仍产出含 webui 的 wheel。",
      "4. 检查无残留：grep 确认无 jinja2/templates/pages.py/view_models 引用残留（文档历史提及除外）。"
    ].join("\n")
  }
];

function implPrompt(ph) {
  return COMMON + "\n\n========== 本阶段任务: " + ph.title + " ==========\n\n" + ph.spec + "\n\n完成后返回 JSON。";
}

function recoveryPrompt(ph) {
  return COMMON + "\n\n========== 恢复中断的阶段: " + ph.title + " ==========\n\n上一次实施尝试未能完成（可能中断在半途）。先检查 git log / git status / 工作树与验证现状，判断已完成部分，补齐缺口直至本阶段 spec 完成且验证全绿后提交。\n\n" + ph.spec + "\n\n完成后返回 JSON。";
}

function fixPrompt(ph, review, round) {
  return COMMON + "\n\n========== 修复检视意见: " + ph.title + "（第 " + round + " 轮） ==========\n\n独立检视者（Kimi K3）对本阶段 diff 提出如下 findings，逐条修复：\n\n" + JSON.stringify(review.findings, null, 2) + "\n\n要求：\n- blocker 与 major 必须全部解决；minor 尽量解决。\n- 若你确有充分技术理由不采纳某条 finding，必须在该 finding 对应处理说明中给出理由；blocker 不允许不处理。\n- 修复后重跑全部适用验证命令并保证全绿，然后以独立提交落盘（如 fix(admin): ...）。\n- 本阶段 spec 原文如下，修复不得偏离：\n\n" + ph.spec + "\n\n完成后返回 JSON（summary 逐条说明每个 finding 的处理结果）。";
}

function reviewPrompt(ph, impl, round, prev) {
  const base = impl && impl.baseCommit ? impl.baseCommit : "main";
  const prevBlock = prev
    ? "\n\n上一轮检视 findings（本轮须逐条核验是否已妥善解决，未解决的保留并注明）：\n" + JSON.stringify(prev.findings, null, 2)
    : "";
  return RCOMMON + "\n\n========== 被检视阶段: " + ph.title + "（第 " + round + " 轮检视） ==========\n\n阶段 spec（检视基准之一）：\n" + ph.spec + "\n\n实施者报告：\n" + JSON.stringify({ summary: impl.summary, commits: impl.commits, verification: impl.verification, notes: impl.notes }, null, 2) + "\n\n本阶段 diff 范围: git -C " + REPO + " diff " + base + "..HEAD（实施前基线 " + base + "）" + prevBlock + "\n\n输出 JSON 裁决。";
}

const KIMI = { provider: "kimi-coding", model: "k3" };

async function kimiReview(ph, impl, round, prev) {
  let r = await agent(reviewPrompt(ph, impl, round, prev), Object.assign({ label: "review:" + ph.id + "#" + round, schema: reviewSchema }, KIMI));
  if (!r) {
    log("kimi review " + ph.id + "#" + round + " failed once, retrying");
    r = await agent(reviewPrompt(ph, impl, round, prev), Object.assign({ label: "review-retry:" + ph.id + "#" + round, schema: reviewSchema }, KIMI));
  }
  return r;
}

const results = [];
const carried = [];

for (let i = 0; i < PHASES.length; i++) {
  const ph = PHASES[i];
  phase("P" + (i + 1) + " " + ph.title);
  log("实施阶段: " + ph.id);

  let impl = await agent(implPrompt(ph), { label: "impl:" + ph.id, schema: implSchema });
  if (!impl || impl.status === "blocked") {
    log("实施 " + ph.id + " 未完成，尝试恢复");
    impl = await agent(recoveryPrompt(ph), { label: "impl-retry:" + ph.id, schema: implSchema });
  }
  if (!impl || impl.status === "blocked") {
    results.push({ id: ph.id, title: ph.title, status: "blocked", detail: impl ? impl.notes : "implementation agent failed twice" });
    return { status: "incomplete", failedAt: ph.id, phases: results };
  }

  let review = await kimiReview(ph, impl, 1, null);
  let rounds = 1;
  while (review && review.verdict === "request_changes" && review.findings.length > 0 && rounds < 3) {
    log("阶段 " + ph.id + " 第 " + rounds + " 轮检视要求修改，进入修复");
    const fix = await agent(fixPrompt(ph, review, rounds), { label: "fix:" + ph.id + "#" + rounds, schema: implSchema });
    if (!fix || fix.status === "blocked") {
      log("阶段 " + ph.id + " 修复受阻");
      break;
    }
    impl = fix;
    rounds += 1;
    review = await kimiReview(ph, impl, rounds, review);
  }

  const verdict = review ? review.verdict : "unreviewed";
  const unresolved = verdict === "request_changes" ? review.findings : [];
  for (const f of unresolved) carried.push({ phase: ph.id, severity: f.severity, file: f.file, issue: f.issue, suggestion: f.suggestion });
  results.push({
    id: ph.id,
    title: ph.title,
    status: "done",
    implSummary: impl.summary,
    commits: impl.commits,
    verification: impl.verification,
    notes: impl.notes,
    reviewRounds: rounds,
    verdict: verdict,
    reviewSummary: review ? review.summary : "Kimi 检视代理不可用",
    unresolvedFindings: unresolved
  });
  log("阶段 " + ph.id + " 完成: " + verdict + " (" + rounds + " 轮检视)");
}

// ---------- 最终门禁: Kimi 全量终审 + 修复闭环 ----------
phase("P9 最终门禁（Kimi K3 终审）");

const finalGate = {
  id: "final",
  title: "全量终审",
  spec: [
    "最终门禁范围（设计 §2.1 目标、§8.5 API 变更清单、§11 质量门禁、§12 全部实施步骤）：",
    "- git -C " + REPO + " diff main..HEAD 全量变更对照设计文档逐项核对。",
    "- §2.1 七项目标逐项判断是否达成；§8.5 API 清单核对（新增 SSE/structure-report/dashboard/summary、增补 progress、其余契约不动）；§11 门禁（tsc、ESLint、Vitest、后端新端点测试、类型契约一致性、README 质量清单）；§12 六个实施步骤全部完成且无越界。",
    "- 各实施阶段结转的未决 findings 一并核验（见附）。"
  ].join("\n")
};

function finalReviewPrompt(round, prev) {
  const prevBlock = prev
    ? "\n\n上一轮终审 findings（逐条核验是否已妥善解决）：\n" + JSON.stringify(prev.findings, null, 2)
    : "";
  return RCOMMON + "\n\n========== 最终终审（第 " + round + " 轮） ==========\n\n" + finalGate.spec + "\n\n结转 findings：\n" + JSON.stringify(carried, null, 2) + "\n\n注意：types.generated.ts 与 openapi.json 的一致性、wheel 含 webui 产物、/api 404 穿透、SSE 生命周期、旧页面层（pages.py/templates/static/view_models/jinja2）已彻底移除，都是终审必查项。diff 范围: git -C " + REPO + " diff main..HEAD" + prevBlock + "\n\n输出 JSON 裁决。";
}

function finalFixPrompt(review, round) {
  return COMMON + "\n\n========== 终审意见修复（第 " + round + " 轮） ==========\n\n终审（Kimi K3）对 main..HEAD 全量 diff 的 findings，逐条修复：\n\n" + JSON.stringify(review.findings, null, 2) + "\n\n要求：blocker 与 major 必须全部解决；minor 尽量解决；有充分技术理由不采纳的必须在 notes 说明。修复后重跑全部验证命令（pytest / ruff / mypy / npm lint+typecheck+test+build / uv build，wheel 须含 webui）并全绿，独立提交。\n\n完成后返回 JSON（summary 逐条说明处理结果）。";
}

let finalReview = await agent(finalReviewPrompt(1, null), Object.assign({ label: "review:final#1", schema: reviewSchema }, KIMI));
if (!finalReview) {
  finalReview = await agent(finalReviewPrompt(1, null), Object.assign({ label: "review-retry:final#1", schema: reviewSchema }, KIMI));
}
let finalRounds = 1;
let finalImpl = null;
while (finalReview && finalReview.verdict === "request_changes" && finalReview.findings.length > 0 && finalRounds < 5) {
  log("终审第 " + finalRounds + " 轮要求修改，进入修复");
  finalImpl = await agent(finalFixPrompt(finalReview, finalRounds), { label: "fix:final#" + finalRounds, schema: implSchema });
  if (!finalImpl || finalImpl.status === "blocked") {
    log("终审修复受阻");
    break;
  }
  finalRounds += 1;
  finalReview = await agent(finalReviewPrompt(finalRounds, finalReview), Object.assign({ label: "review:final#" + finalRounds, schema: reviewSchema }, KIMI));
  if (!finalReview) {
    finalReview = await agent(finalReviewPrompt(finalRounds, finalReview), Object.assign({ label: "review-retry:final#" + finalRounds, schema: reviewSchema }, KIMI));
  }
}

const finalVerdict = finalReview ? finalReview.verdict : "unreviewed";
const finalUnresolved = finalVerdict === "request_changes" ? finalReview.findings : [];

return {
  status: finalVerdict === "approve" ? "completed" : (finalVerdict === "unreviewed" ? "unreviewed" : "review_failed"),
  phases: results,
  carriedFindingsIntoFinal: carried,
  final: {
    reviewRounds: finalRounds,
    verdict: finalVerdict,
    reviewSummary: finalReview ? finalReview.summary : "Kimi 终审代理不可用",
    unresolvedFindings: finalUnresolved,
    lastFixReport: finalImpl ? { summary: finalImpl.summary, commits: finalImpl.commits, verification: finalImpl.verification, notes: finalImpl.notes } : null
  }
};
