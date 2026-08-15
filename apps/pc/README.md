# Engirdle PC 内容生产端

PC 端采用模块化 Python 单体。管理 Web、单 Worker 与局域网只读发布端共享领域和应用模块，但使用独立进程入口及路由表。

## 当前能力

- 录入标题、英文 Markdown、作者、来源与许可，并分别保存原始/规范化文本及哈希；
- 解析冻结的 GFM 子集（标题、段落、列表、引用、强调/加粗/删除线、链接、行内代码、表格、代码块、分隔线），生成带行内 runs 的类型化文档；
- 在管理页面合并、拆分、编辑、重排并冻结结构；结构确认页展示解析警告、结构树和派生的翻译/朗读资格（只读，不可手工切换）；
- 通过 DeepSeek `deepseek-v4-flash` 进行“代码零泄漏的完整上下文 + 顺序翻译单元”翻译：文本句按批请求（行内代码与链接 URI 用占位符保护），整表一次结构化请求并强制同形状返回；人工修正与原始输出分别保存；
- 用本地 Qwen3-TTS CustomVoice 生成英文锚点候选，试听确认后冻结为版本化、唯一激活的声音配置；
- 用本地 Qwen3-TTS Base 从激活锚点创建每任务一次的可复用 clone prompt，逐句合成 24 kHz 单声道 PCM（表格、代码块和分隔线不进入任何 LLM 或 TTS 请求）；
- 持久化任务阶段、尝试次数、心跳、配置快照、检查点和结构化失败，失败后复用已接受的翻译单元与有效句级 PCM；
- 审阅并修正句译与整表译文（表格按 cell 修正，保存时校验形状），逐句试听音频并查看缺失、零时长和异常时长检查；音频审阅只列出可朗读句子；
- 以峰值与 loudnorm 一致化、64 kbps AAC-LC 编码音频，并把编码参数写入 manifest；
- 构建、重开校验并原子发布 Readpack 1.1（声明 `markdown-blocks` 能力，携带 runs、表格与代码块）和 `catalog.json`，失败时保持旧目录和旧包可用；
- 创建正文新修订、重建同一修订、重新发布既有不可变制品，以及确认后将本地文章移入可恢复 trash；
- 在管理页查看绑定地址、风险与持久化进程状态，并启停独立只读发布进程；管理端重启后仍可识别和停止遗留进程，发布进程仅提供 `GET/HEAD /catalog.json` 和固定包路由。

翻译与 TTS 的生产默认均为真实适配器（DeepSeek API / 本地 Qwen3-TTS）。确定性 stub 只作为测试 fixture 存在于 `tests/`（`translation_fake.py`、`speech_fake.py`），生产代码与入口不引用、不回退到 stub；缺少 TTS 依赖或模型文件时入口进程直接报错退出。

## 安装

需要 Python 3.10+ 与 `uv`。FFmpeg 由锁定的 Python 依赖提供，不读取仓库根目录 `.tts/`。

```bash
cd apps/pc
uv sync --extra dev
```

运行真实 TTS 还需要可选的 `tts` extra（torch/qwen-tts/soundfile 等，含 CUDA 轮子）：

```bash
uv sync --extra dev --extra tts
```

默认 workspace 是 `~/.local/share/engirdle`。可为开发或验收指定仓库外目录：

```bash
export ENGIRDLE_WORKSPACE=/absolute/path/to/engirdle-workspace
```

## 语音模型与声音配置

Qwen3-TTS 检查点放在应用管理的本地模型目录（默认 `~/.local/share/engirdle/models`，可用 `ENGIRDLE_SPEECH_MODEL_ROOT` 覆盖）：

```text
models/
├── Qwen3-TTS-12Hz-1.7B-CustomVoice/
└── Qwen3-TTS-12Hz-1.7B-Base/
```

把本机已有的检查点复制进去即可（约 8.6 GB），例如从仓库根目录的调研副本：

```bash
mkdir -p ~/.local/share/engirdle/models
cp -r .tts/Qwen3-TTS-12Hz-1.7B-CustomVoice .tts/Qwen3-TTS-12Hz-1.7B-Base \
  ~/.local/share/engirdle/models/
```

生产代码只读取该模型目录，从不导入或回退到 `.tts/`；模型不进入 Git、安装包或 readpack。

其他 `ENGIRDLE_SPEECH_*` 部署配置（均为非秘密项，有默认值）：`SPEECH_DEVICE`（`cuda:0`）、`SPEECH_DTYPE`（`bfloat16`）、`SPEECH_ATTN_IMPLEMENTATION`（`sdpa`）、`SPEECH_SEED`（`0`）、`SPEECH_MAX_NEW_TOKENS`（`2048`）、`SPEECH_ANCHOR_CANDIDATES`（`3`）。

首次使用前，在管理端“声音配置”页选择英文 speaker（Ryan/Aiden）、锚点朗读文本与风格 instruct，生成候选并试听；确认某个候选会把它冻结为不可变锚点（记录 WAV 哈希、seed 与参数）并设为当前激活配置。调整任何一项都会创建新修订，已发布制品引用的旧修订保持可读。生产任务只使用激活配置：Worker 为每个任务创建一次 clone prompt 后逐句复用，CustomVoice 仅在生成锚点时加载、用完即释放，两个 1.7B 检查点不会同时常驻。

## 运行完整生产流程

启动管理端与 Worker：

```bash
uv run engirdle-pc admin
uv run engirdle-pc-worker
```

- 管理端：`http://127.0.0.1:8765`
- 发布端：`http://<LAN 地址>:8766/catalog.json`

发布端默认由管理页的“局域网只读服务”面板启停；它没有鉴权，只应在受信任的局域网临时开启。也可用 `uv run engirdle-pc publisher` 手工启动独立发布进程。

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
