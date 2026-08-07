# Engirdle PC 内容生产端

PC 端采用模块化 Python 单体。管理 Web、单 Worker 与局域网只读发布端共享领域和应用模块，但使用独立进程入口及路由表。

## 当前能力

- 录入标题、正文、作者、来源与许可，并分别保存原始/规范化文本及哈希；
- 识别段落、列表项和引用块，在块内英文分句；
- 在管理页面合并、拆分、编辑、重排并冻结结构；
- 持久化任务阶段、尝试次数、心跳、配置快照、检查点和结构化失败；
- 审阅并修正句译、抽听文章音频；
- 构建、重开校验并原子发布 `.readpack` 和 `catalog.json`；
- 创建正文新修订、重建同一修订，以及确认后将本地文章移入可恢复 trash；
- 只读发布进程仅提供 `GET/HEAD /catalog.json` 和固定包路由。

翻译与 TTS 是明确标识的 deterministic stub。翻译桩不会联网，TTS 桩生成可听音调 PCM；它们用于验证完整生产流程，不能作为正式内容质量结果。模块端口和任务快照已经为 DeepSeek/Qwen3-TTS 实现预留边界。

## 安装

需要 Python 3.10+ 与 `uv`。FFmpeg 由锁定的 Python 依赖提供，不读取仓库根目录 `.tts/`。

```bash
cd apps/pc
uv sync --extra dev
```

默认 workspace 是 `~/.local/share/engirdle`。可为开发或验收指定仓库外目录：

```bash
export ENGIRDLE_WORKSPACE=/absolute/path/to/engirdle-workspace
```

## 运行完整生产流程

分别启动三个进程：

```bash
uv run engirdle-pc admin
uv run engirdle-pc-worker
uv run engirdle-pc publisher
```

- 管理端：`http://127.0.0.1:8765`
- 发布端：`http://<LAN 地址>:8766/catalog.json`

在管理端录入文章并确认结构；Worker 完成生成后，任务进入 `review_required`。修正译文并抽听音频后发布，目录才会切换到新制品。失败任务不会改变已有 catalog 指针。

单步演练可使用 `uv run engirdle-pc worker-once`；`uv run engirdle-pc check` 会初始化数据库并重建 catalog。

## 质量检查

```bash
uv run ruff check hatch_build.py src tests
uv run mypy src
uv run pytest
uv build
```

测试直接使用根目录 `contracts` 中的合法/非法 fixtures，并包含从空数据库完成“录入 → 生成 → 审阅 → 发布 → 下载”的黑盒流程、失败重试、租约恢复、只读路由隔离和旧制品保护。
