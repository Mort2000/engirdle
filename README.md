# Engirdle

Engirdle 是面向英文长文精读的本地优先工具。本仓库当前包含跨端 readpack/catalog 契约、PC 内容生产端 MVP 与 Android 客户端 MVP。

## PC 生产端

PC 端位于 `apps/pc`，采用 Python 模块化单体：

- 管理 Web/API 仅绑定回环地址，负责录入、结构确认、任务和人工审阅；
- 单 Worker 串行执行翻译、逐句语音、音频时间线与编码；
- 发布应用是独立只读入口，只暴露 catalog 和不可变 readpack；
- SQLite 保存元数据，源文件、工作文件和制品保存在仓库外 workspace；
- 翻译与 TTS 当前是确定性验证桩；音频时间线、AAC 编码、打包、校验和发布均走真实实现。

详细运行与验证方式见 [apps/pc/README.md](apps/pc/README.md)。跨端协议见 [contracts/README.md](contracts/README.md)。

## Android 客户端

移动端位于 `apps/mobile`，Flutter 实现：

- 从局域网 PC 发布服务发现并下载不可变 readpack，校验通过后原子切换安装；
- 离线听读：逐句音频区间播放、连续朗读、整文/单句翻译抽屉、选词查词典；
- 生词一步保存、快照随文章删除仍可读；三预设主题与排版设置；
- 本地优先：默认离线，任何联网都需用户显式触发，目录结果不落盘。

详细架构、技术决策与验证方式见 [apps/mobile/README.md](apps/mobile/README.md)。
