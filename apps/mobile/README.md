# Engirdle Android 客户端（apps/mobile）

Flutter 实现的移动端 MVP：从局域网 PC 发布服务下载不可变 readpack，离线完成听读、查词和生词管理。设计依据为 `.scratch/mvp/mvp_design.md` 与 `.scratch/android_design/index.html`（17 屏高保真稿）。

## 架构

模块化单体 + 组合根（`lib/app/dependencies.dart`）。状态管理使用 Flutter 内置 `ChangeNotifier`/`ValueNotifier` + `ListenableBuilder`，依赖通过 `AppScope`（InheritedWidget）注入；不引入 riverpod/bloc，无任何 codegen。

```
lib/
├── main.dart                     # 启动：装配依赖 → 导入恢复 → runApp
├── app/                          # 组合根、路由、主题（三预设）、去工程化文案
├── shared_kernel/                # 内容身份（ArticleRef/SentenceRef）、错误分类、ID 生成
├── contracts/                    # readpack v1 / catalog v1 的 Dart 模型与运行时校验器
│                                 #   （镜像 ../../contracts 下的 JSON Schema + 兼容规则）
├── platform/                     # 与业务无关的技术底座
│   ├── database/                 #   SQLite 打开 + PRAGMA user_version 迁移链（v1 全量建表）
│   ├── filesystem/               #   受控目录布局，ID 校验后才可成为路径段
│   ├── http/                     #   LAN HTTP 客户端（明文仅限私网/localhost，超时+大小上限+取消）
│   ├── zip/                      #   自研安全 ZIP 读取器（预检中央目录，流式解压真实字节计数）
│   ├── crypto/                   #   流式 SHA-256
│   └── logging/                  #   结构化日志
└── features/                     # 业务模块，各自 application/domain/infrastructure/presentation 分层
    ├── connection/               # 服务地址保存与验证（01/02/16 屏）
    ├── catalog/                  # 目录拉取与更新状态比较（不缓存，仅会话级）
    ├── importer/                 # 下载→外层哈希→ZIP 预检→解压→校验→原子换指针→清理 + 启动恢复
    ├── library/                  # 书架、已装内容索引、删除、阅读模式
    ├── reader/                   # 阅读页、逐句选择手势、句菜单/翻译抽屉
    ├── playback/                 # 单会话播放状态机（engine 端口 + just_audio 适配器）
    ├── dictionary/               # 独立版本化词典资源、原样→规范化→lemma 查询顺序
    ├── vocabulary/               # 一步保存 + 撤销；快照无 FK，文章删除后仍可读
    ├── preferences/              # 字号/行高/边距/三预设主题
    └── attribution/              # 归属信息页（15 屏）
```

## 关键技术决策

- **SQLite 裸 SQL（package:sqlite3），不用 Drift**：MVP 无 codegen，迁移集中在 `platform/database/migrations.dart` 的 PRAGMA user_version 链；表所有权按模块划分，DAO 只写自己的表。
- **自研安全 ZIP 读取器，不引 archive 包**：安全规则必须自控——预检阶段拒绝路径穿越（含反斜杠变体）、绝对路径、重复规范化路径、目录条目、符号链接/设备文件、加密条目、多盘/ZIP64 与未知压缩方法；限制条目数（64）、单条目（1 GiB）、总展开（1 GiB）与路径长度（240）；解压按真实写出字节计数，必须与中央目录声明完全一致。
- **LAN HTTP 策略**：`http://` 仅允许私网 IPv4 字面量（10/8、127/8、169.254/16、172.16/12、192.168/16）与 `localhost`，其余明文地址在请求发出前拦截；`https://` 任意；所有请求有有限超时与响应上限。
- **导入原子性（MOB-IMP-002/003）**：暂存解压校验 → rename 到不可变制品目录 → 单事务切换 DB 指针 → 清理。任何失败不触碰旧版本；`import_operations` 恢复日志覆盖 downloading/staged/moving/committed/failed 五态，启动时 `recoverUnfinished()` 重放或回滚。清理阶段失败不会删除已提交内容，留待下次启动重试。
- **播放为单会话状态机**：`PlaybackController` 持有会话 token，新的「单句朗读/从此朗读」取代旧会话时才弹提示（UX-A2）；离开阅读页即停（无后台播放，MVP 排除项）。
- **生词一步保存（UX-A1）**：词典抽屉内点「保存该义项」即落库（该动作即义项选择），snackbar 提供撤销（=删除刚插入的行）；快照含句子、译文与词典版本，与文章表无外键关联。

## 与设计稿的有意偏差

- **书架/生词本的搜索图标未实现**：设计稿有图标但无交互规格，PRD 也无搜索需求，按「不交付无规格交互」省略。
- **目录未安装条目不显示作者/音频时长**：设计稿 03B 有，但 catalog v1 契约不含这两个字段；当前显示「未安装」，包大小只在 04 下载页出现（设计同时要求工程信息不进列表）。属设计稿-契约冲突，待契约演进。
- **仅中文模式标题回退为英文原题**：设计稿 s08 显示中文译名，readpack v1 契约只有 `title` 字段。
- **选词高亮只有底色、无描边**：系统选区样式无法表达描边，三色预设的 `selectHighlight` 已接线为选区底色。
- **s02「权限拒绝 + 打开系统设置」路径不存在**：Android `INTERNET` 为安装期权限、运行时不可撤销；权限卡文案已改为与事实一致的「公网明文请求在应用内一律拒绝」。
- **s09 选区约束提示 snackbar、17B 骨架列表、词菜单图标/义项序号等装饰性元素**未做（不影响交互语义）。

## 运行

需要 Flutter 3.44+（Dart 3.12+）与 Android SDK/设备。本仓库不提交 Flutter SDK 与构建产物。

```bash
flutter pub get
flutter analyze
flutter test                 # 单元 + 契约 fixtures + widget 冒烟
flutter run                  # 连接 Android 设备/模拟器
```

`android/` 未提交 Gradle wrapper；首次构建前在 `apps/mobile` 执行一次 `flutter create . --platforms android` 补齐 wrapper 即可（不会覆盖已提交的 `android/app` 内容）。

## 测试

`test/` 镜像 `lib/` 结构：

- `test/contracts/`：直接消费仓库 `contracts/readpack/v1`、`contracts/catalog/v1` 的 fixtures——valid 包通过完整解压校验，11 个非法 readpack 与 5 个非法 catalog 各自按 fixtures/README 文档的首个失败原因被拒绝；
- `test/platform/`：恶意 ZIP 矩阵（手写最小 ZIP 构造器伪造声明大小/标志位/Unix 模式）、LAN URL 策略、基于回环 `HttpServer` 的传输上限与取消语义；
- `test/features/`：词典查询顺序与降级、生词快照/撤销/无 FK、导入全链路（真实 fixture 经回环 HTTP 服务器下载，成功/哈希不符/HTTP 失败/两种启动恢复路径）；
- `test/widget_smoke_test.dart`：首启路由、生词本空态、排版设置页渲染（假播放引擎 + 内存数据库）。

## 待办（不在本次交付）

- 真实词典资源格式与安装流（依赖 PC 端 G4 词典构建器）；
- 选词手势的真机交互微调；
- Android 真机/模拟器运行验证（debug APK 构建已在本机验证通过，尚未上机运行）。
