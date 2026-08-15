# Engirdle

Engirdle 是面向英文长文精读的本地优先工具。本仓库当前包含跨端 readpack/catalog 契约、PC 内容生产端 MVP 与 Android 客户端 MVP。

## PC 生产端

PC 端位于 `apps/pc`，采用 Python 模块化单体：

- 管理 Web/API 仅绑定回环地址，负责 Markdown 录入、结构确认、任务和人工审阅；
- 录入解析冻结的 GFM 子集（标题、列表、引用、表格、代码块、分隔线与行内样式），生成类型化文档；
- 单 Worker 按 ProcessingPlan 分流：文本句按批翻译并逐句合成语音，整表一次 LLM 请求且不朗读，代码块永不进入任何 LLM/TTS 请求；
- 发布应用是独立只读入口，只暴露 catalog 和不可变 readpack（v1.1 声明 markdown-blocks 能力）；
- SQLite 保存元数据，源文件、工作文件和制品保存在仓库外 workspace；
- 翻译与 TTS 当前是确定性验证桩；音频时间线、AAC 编码、打包、校验和发布均走真实实现。

详细运行与验证方式见 [apps/pc/README.md](apps/pc/README.md)。跨端协议见 [contracts/README.md](contracts/README.md)。

## Android 客户端

移动端位于 `apps/mobile`，Flutter 实现：

- 从局域网 PC 发布服务发现并下载不可变 readpack（v1.0 与 v1.1 markdown-blocks），校验通过后原子切换安装；
- 离线听读：逐句音频区间播放、连续朗读、整文/单句翻译抽屉、选词查词典；
- Markdown 渲染：标题/列表/引用排版、行内富文本（runs）、横向滚动表格（双语 cell 内对照）、等宽代码块与分隔线；表格与代码不参与播放；
- 生词一步保存、快照随文章删除仍可读；三预设主题与排版设置；
- 本地优先：默认离线，任何联网都需用户显式触发，目录结果不落盘。

详细架构、技术决策与验证方式见 [apps/mobile/README.md](apps/mobile/README.md)。
