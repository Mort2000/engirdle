# 英英/英汉词典数据源背景调研

> 调研日期：2026-08-09
>
> 范围：仅核查数据/项目官方仓库、官方发布页和官方许可证页面。本文是工程选型记录，不是法律意见；“个人研究可用”不自动等于“可以随应用或资源包再分发”。

## 1. 对项目需求的提炼

结合 [移动端离线词典加载方案](./mvp/mobile_offline_dictionary_loading.md) 和 [项目目的](./purpose.md)，词典数据需要满足：

- PC 端可下载、裁剪、规范化并构建成独立版本化资源包；移动端只读打开 SQLite，不应依赖在线 API。
- 至少支持原样短语、规范化词形和 lemma 查询；因此候选数据最好有词头、词性、义项/释义和词形信息，或允许在 PC 端预计算 `forms`。
- 英英结果应适合“阅读时快速扫一眼”，英汉结果作为补充；不要求一开始覆盖所有词汇或提供完整学习体系。
- 词典必须能独立升级，包内记录数据版本、来源、许可证、归属、修改/裁剪说明和哈希；不同来源最好保留独立的 `source_id`，不要把混合数据误写成单一许可证。
- 目标是单用户、离线优先的个人研究工具。当前可以接受 PC 端较重的解析/转换，但 Android 端查询和安装必须轻量、可校验、可回滚。

## 2. 结论摘要

### 推荐的 MVP 组合

1. **英英首选：Open English WordNet 2025**。官方同时提供 JSON、GWN-LMF XML、RDF 和传统 WNDB；数据带 synset gloss/definition、词性和词汇关系，且 Open English WordNet 部分按 CC BY 4.0 发布。JSON 或 LMF 很适合作为 PC 构建器输入。它主要覆盖名词、动词、形容词和副词，不应被当成完整学习词典；还需要保留其 Princeton WordNet 上游许可归属。
2. **英汉首选：FreeDict `eng-zho`**。官方当前下载目录列出 2025.11.23 版、26,660 个 headwords，并直接提供 TEI 源码、StarDict、DICTD 和 SLOB 构建产物。源 TEI 头部明确写出 CC BY-SA 3.0、Wiktionary/DBnary 来源，体积适合先做独立资源包。
3. **覆盖率增强候选：Wiktionary dump + Wiktextract**。它能同时抽取英文释义、词性、词形、发音、例句和多语言 translations，最接近长期完整方案；代价是下载/解析/质量筛选成本高，且需要严格处理 Wikimedia 的 CC BY-SA/GFDL、页面内其他来源及归属要求。

### 暂不建议直接作为可再分发 MVP 包

- **ECDICT** 的工程形态非常合适，但官方 README 自述数据是多年从多个外部资料、BNC、WordNet 等来源拼合和补充而来，仓库只有一个 MIT `LICENSE`，不足以证明每个数据字段都由 MIT 清权。适合先下载到本地做质量和覆盖率实验；在完成逐字段来源审计前，不建议把原始或裁剪后的数据放入可供他人下载的 `.dictpack`。
- **CC-CEDICT** 是中文→英文，不是现成的英文→中文词典。可以把英文 gloss 反向建索引，但一个英文 gloss 可能对应多个中文词，且原格式没有适合本项目的英文词性/lemma 结构；更适合作为英汉补充或中文词条反查数据。

## 3. 候选逐项核查

### 3.1 Open English WordNet（英英，推荐）

**内容与格式**

- 官方 README 将它定义为按 synset 组织的英语 lexical network，包含 hypernymy、antonymy、meronymy 等关系；代码示例直接调用 `synset.definition()`，因此可以抽取英英释义、词性、synset、例句/关系等字段。
- 2025 版官方发布 JSON、GWN-LMF XML、RDF 和 WNDB；2025+ 另含经过人工验证的部分 proper nouns。官方列出的 2025+ 规模为 161,875 words、120,564 synsets、419,226 relations；核心 2025 版为 135,969 words、107,519 synsets、355,064 relations。
- LMF 的 lexical entry、sense、synset 和 relation 标识规则有官方 `FORMAT.md`，适合构建器稳定地生成 `entries`、`senses`、`relations` 和 `forms`。若只做阅读查词，首期可以只抽 lemma、POS、definition、example 和稳定 ID。

**下载/打包可行性**

- 直接使用官方 JSON zip 或 LMF gzip；PC 构建器流式读取后写入 SQLite 即可，不必在手机端加载整个原始文件。
- 可将一词多义拆成独立 sense 行，并以 `synset_id`/source ID 做稳定关联；形态查询仍应在构建阶段补充 forms，因为 WordNet 官方 FAQ 说明其词形处理是单向规则与不规则表，并不能保证生成所有屈折形式。

**许可与再分发**

- Open English WordNet 自身按 CC BY 4.0 发布，允许分享和改编，但分享时必须归属 Open English WordNet 团队并遵守 CC BY 条件。
- 它是 Princeton WordNet 的衍生资源；官方许可证文件明确要求同时遵守底层 Princeton WordNet license。Princeton 条款允许使用、复制、修改和分发，但要求在所有副本（含修改版）保留版权声明、许可/免责声明等文字。
- **判断：适合个人研究，也适合构建可再分发的独立数据库，但 manifest/归属页必须同时列出 Open English WordNet CC BY 4.0 和 Princeton WordNet 的版权/许可说明；不要只写“CC BY”。**

原始来源：

- [Open English WordNet 官方 README](https://github.com/globalwordnet/english-wordnet/blob/main/README.md)
- [Open English WordNet 官方格式说明](https://github.com/globalwordnet/english-wordnet/blob/main/FORMAT.md)
- [Open English WordNet 官方许可证](https://github.com/globalwordnet/english-wordnet/blob/main/LICENSE.md)
- [Open English WordNet 2025 官方 release](https://github.com/globalwordnet/english-wordnet/releases)
- [Princeton WordNet 官方许可页](https://wordnet.princeton.edu/license-and-commercial-use)
- [Princeton WordNet 官方 FAQ：数据库格式与词形处理](https://wordnet.princeton.edu/frequently-asked-questions)

### 3.2 Princeton WordNet 3.0（英英，稳定/轻量备选）

**内容与格式**

- WordNet 官方说明数据库是 ASCII 格式的八个主要文件，每种 syntactic category 两个文件；官方文档完整描述 `data.*`、`index.*`、sense 和 morph 相关格式。
- 内容以 synset 和 glossary definition 为核心，定义和例句由 synset 共享；官方 FAQ 明确指出主要覆盖 open-class nouns、verbs、adjectives、adverbs，不包含 determiner、preposition、pronoun、conjunction 等 closed-class 词。

**下载/打包可行性**

- 官方下载页继续提供 WordNet 包；ASCII 文件很容易在 PC 端解析并转换成 SQLite，原始包也适合保存为构建输入。
- 结构稳定、解析成本低，适合先做安装器和查询链路的黄金词典；但版本较老，现代词汇和学习型标签不足。建议把它作为 Open English WordNet 的小型兼容测试源，而不是长期唯一英英源。

**许可与再分发**

- Princeton 官方许可允许出于任何目的免费使用、复制、修改和分发软件、数据库及文档，但要求所有副本和修改版保留版权声明、许可相关文字和免责声明，并不得用 Princeton 名称作宣传背书。
- **判断：个人研究和自建 SQLite 都没有明显许可障碍；若发布 `.dictpack`，必须把官方 LICENSE 原文或可访问链接与归属一起带上。**

原始来源：

- [WordNet 官方首页/下载入口](https://wordnet.princeton.edu/)
- [WordNet 官方 FAQ：数据库格式](https://wordnet.princeton.edu/frequently-asked-questions)
- [WordNet 官方文档索引](https://wordnet.princeton.edu/documentation)
- [WordNet 官方许可页](https://wordnet.princeton.edu/license-and-commercial-use)

### 3.3 GNU GCIDE 0.54（英英，传统词典备选）

**内容与格式**

- GNU 官方 FTP 当前列出 `gcide-0.54`；官方包的 README 标明版本为 0.54（2024-12-31），数据位于按字母拆分的 `CIDE.*` 文件中。
- `CIDE.*` 是带标记的文本格式，README 还描述了 tagset、发音和 GNU Dico 查询方式。它比 WordNet 更接近传统词典条目，但需要解析自有标记后再映射到 lemma、POS、definition、usage note 等字段。

**下载/打包可行性**

- 官方提供 tar.gz、tar.xz 和 zip；官方目录显示 tar.xz 约 14 MiB，适合作为 PC 构建器输入。数据本身不是 SQLite，需要一次性清洗/解析，但数据体积对个人研究很友好。
- 内容偏传统、历史和一般词典风格，不能假设它拥有现代学习者所需的完整词形、频率或短语覆盖；建议只作为第二个英英来源或离线兜底。

**许可与再分发**

- 官方发布包内的 `COPYING` 是 GPLv3。GPL 允许复制、修改和分发，但分发修改版需要遵守 GPL 的源代码/许可通知等义务；把数据放进应用包前应让整个发布策略明确承担相应义务。
- **判断：个人本地研究可用；技术上可构建和再分发，但许可义务比 WordNet/OEWN 更重，MVP 不宜把它和宽松许可数据无标记地合并。**

原始来源：

- [GNU 官方 GCIDE 发布目录](https://ftp.gnu.org/gnu/gcide/)
- [GNU GCIDE 官方 README/发布说明（包内文件）](https://ftp.gnu.org/gnu/gcide/gcide-0.54.tar.xz)
- [GNU GCIDE 官方源码包](https://ftp.gnu.org/gnu/gcide/gcide-0.54.tar.gz)
- [GNU GPL 官方文本](https://www.gnu.org/licenses/gpl-3.0.html)

### 3.4 FreeDict `eng-zho`（英汉，推荐先做 MVP）

**内容与格式**

- FreeDict 官方下载页列出 English–Chinese `eng-zho` 2025.11.23，26,660 headwords；官方 API 元数据还列出 source、版本、SHA-512、源码包和多种构建格式。
- 官方源包内的 `eng-zho.tei` 是 TEI XML。其 `teiHeader` 给出标题、版本、headword 数、来源和许可证；条目包含英文 `orth`、可选 pronunciation/POS、英文 `def`，以及中文 `cit type="trans" xml:lang="zh"`，与本项目的英汉释义字段直接对应。
- 官方同时发布 StarDict、DICTD 和 SLOB 构建产物。对本项目不建议直接把 StarDict 当运行时格式，而是读取 TEI 源或 StarDict 后统一构建 Engirdle 的 SQLite schema。

**下载/打包可行性**

- 源码包约 1.6 MiB，StarDict 压缩包约 1.7 MiB，SLOB 约 3.4 MiB（官方 JSON 元数据中的 `size` 字段）；非常适合先实现下载、SHA 校验、解包、SQLite 预检和离线查词。
- 这是一个偏小的英汉词典，不能把 26,660 headwords 当作完整现代英语覆盖；适合作为第一版可再分发数据和测试数据，后续可与独立英英源并存而不是直接覆盖。

**许可与再分发**

- 2025.11.23 源 TEI 头部明确声明 CC BY-SA 3.0，并注明数据由 WikDict 自动生成、基础数据来自 Wiktionary via DBnary。
- FreeDict 官方文档说明每个词典的许可证以 TEI 文件头部为准，并允许在满足相应许可证条件下学习、修改、扩展和再发布；不能只依据 FreeDict 总站“多数词典是 GPL”的概述来替代本词典头部的 CC BY-SA 3.0。
- **判断：这是当前最适合 Engirdle MVP 的现成英汉源。构建 SQLite 属于格式/技术转换，仍需保留 CC BY-SA 3.0、WikDict/DBnary/Wiktionary 来源、版本和修改说明，并让再发布的数据库/内容满足 Share-Alike 与 attribution 要求。**

原始来源：

- [FreeDict 官方下载页](https://freedict.org/zh_cn/downloads/)
- [FreeDict 官方元数据 API](https://freedict.org/freedict-database.json)
- [FreeDict 官方文档：TEI 格式与许可复用](https://freedict.org/zh_cn/documentation/)
- [FreeDict `eng-zho` 2025.11.23 源码包](https://download.freedict.org/dictionaries/eng-zho/2025.11.23/freedict-eng-zho-2025.11.23.src.tar.xz)
- [CC BY-SA 3.0 官方法律文本](https://creativecommons.org/licenses/by-sa/3.0/legalcode)

### 3.5 ECDICT（英汉，覆盖率候选/需审计）

**内容与格式**

- 官方仓库将其定义为 English→Chinese 双解数据库。`ecdict.csv` 是 UTF-8 CSV，字段包括 `word`、`phonetic`、英文 `definition`、中文 `translation`、`pos`、词频/标签和 `exchange` 词形变换；仓库同时提供转换到 SQLite/MySQL 的代码和 StarDict 相关工具。
- 官方 README 当前把 GitHub 上的 CSV 描述为基础版本（约 76 万词条），另有压缩的 StarDict 数据；它直接满足“英文释义 + 中文释义 + 词形”的查询模型，工程上是最省转换工作的候选之一。

**下载/打包可行性**

- CSV 适合做可审查的 PC 输入，SQLite/StarDict 适合本地查询；可以按项目的高频词或文章词汇裁剪，预计算规范化键和 forms 后生成小包。
- 但仓库历史和 README 说明数据来自 EDictAZ、cdict、BNC、WordNet、NodeBox 及网友补充等多个来源，并包含 Collins/Oxford/BNC 等标签字段；这使得字段级来源与再分发边界不能仅从仓库 MIT 文件推出。

**许可与再分发**

- 官方仓库根目录 `LICENSE` 是 MIT，文本允许复制、修改、发布、再许可和销售，并要求保留 MIT 版权/许可文本。
- **关键限制判断：MIT 文件明确覆盖的是仓库中的 “Software”，而 README 自述数据含多个外部来源和第三方标记；因此不能把“仓库显示 MIT”当成整个数据集所有内容都已获得可再分发授权。** 个人本地研究、质量评估和不对外分享的派生 SQLite 风险较低；公开下载或随应用分发前应删掉未清权的标签/字段，或逐来源获得许可证据。

原始来源：

- [ECDICT 官方仓库 README](https://github.com/skywind3000/ECDICT/blob/master/README.md)
- [ECDICT 官方仓库数据文件](https://github.com/skywind3000/ECDICT/blob/master/ecdict.csv)
- [ECDICT 官方仓库 LICENSE](https://github.com/skywind3000/ECDICT/blob/master/LICENSE)
- [ECDICT 官方 raw LICENSE 文本](https://raw.githubusercontent.com/skywind3000/ECDICT/master/LICENSE)

### 3.6 CC-CEDICT（中文→英文，英汉反查补充）

**内容与格式**

- CC-CEDICT 官方项目明确定位为可下载的 Chinese-English dictionary。当前 V2 语法是一行纯文本：`Traditional Simplified [[pinyin]] /gloss; gloss/.../`；slash 分 sense，semicolon 分同一 sense 的 gloss。
- 它提供繁体、简体、拼音和英文 gloss，但官方规范明确说它是 human-readable descriptive dictionary、不是面向机器处理的资源，也不要求用词性标记。将英文 gloss 反向索引为 English→Chinese 会产生歧义和噪声，不等同于真正的英汉词典。

**下载/打包可行性**

- 官方 Wiki 提供 V1、Mixed、V2 三种定期下载版；解析纯文本并写入 SQLite 很简单，适合做中文词条、拼音或反向检索补充。
- 若只保留原始 `zh -> en` 方向，字段映射清晰；若构建 `en -> zh`，必须记录这是 reverse index，并保留 sense/来源关联，不能把英文 gloss 当成可靠 lemma。

**许可与再分发**

- 官方首页声明 CC-CEDICT 使用 CC BY-SA 3.0；因此可以改编和再分发，但要履行 attribution 和 Share-Alike 条件。
- 官方规范还提醒当前数据库存在遗漏、错误和不准确条目，需在导入前做质量抽样。
- **判断：可用于个人研究和补充数据；不建议单独作为 Engirdle 的英汉 MVP 主源。**

原始来源：

- [CC-CEDICT 官方首页与许可证声明](https://cc-cedict.org/wiki/)
- [CC-CEDICT 官方 V2 格式说明](https://cc-cedict.org/wiki/syntax_v2)
- [CC-CEDICT 官方下载入口](https://cc-cedict.org/editor/editor.php?handler=Download)
- [CC BY-SA 3.0 官方法律文本](https://creativecommons.org/licenses/by-sa/3.0/legalcode)

### 3.7 Wikimedia English Wiktionary dump + Wiktextract（英英/英汉，长期覆盖方案）

**内容与格式**

- Wikimedia 官方提供 English Wiktionary 的 XML dump；官方 dump 许可页说明文本内容通常以 GFDL 和 CC BY-SA 4.0 提供，但具体页面可能只有 CC、包含额外许可或存在尚未发现的侵权内容，必须以 Terms of Use 和 dump 内信息为准。
- 官方 Wiktextract 仓库提供从 `enwiktionary-<date>-pages-articles.xml.bz2` 解析为 JSONL 的工具。其官方说明可抽取 word、POS、senses/glosses、forms、sounds、examples、translations、etymology 等；translations 包含语言代码和目标词，可筛选 `zh`/Chinese 得到英汉补充。
- 该路线的信息量最丰富，但原始 XML 是 wikitext，不是可直接查询的结构化表；必须在 PC 端跑解析器、模板/Lua 展开、去重、语言与词性筛选、质量规则和版本冻结。

**下载/打包可行性**

- 官方 dump 入口可按日期下载，Wiktextract 输出 JSONL，适合流式筛选后写入 SQLite；不要把全量 JSONL 放进 Android。
- Wiktextract 官方 README 明确提示，完整 English Wiktionary 抽取可能从约一小时到数天，取决于机器；这符合“PC 重处理、移动端轻消费”，但不适合把首个 MVP 的构建链路做得过重。
- 推荐将英英和英汉分别抽取为 `wiktionary-en` 与 `wiktionary-en-zh`，保留 page/sense/edition 日期与原始 dump URL；不要未经质量筛选把所有语言/模板内容直接展示给阅读用户。

**许可与再分发**

- Wikimedia 官方许可页允许 Wikimedia 项目内容被分享、复制、改编和用于商业目的，但要求按具体项目/页面许可履行义务；文本通常涉及 CC BY-SA 4.0 和 GFDL，且有额外许可、例外和潜在未发现侵权内容的警告。
- Wiktextract 代码本身是 MIT，但这不改变被抽取的 Wiktionary 数据所适用的许可证。应分别记录“解析器代码许可证”和“数据许可证”。
- **判断：个人研究非常适合，长期覆盖最佳；可再分发但合规成本最高。若进入正式词典包，必须提供 attribution、CC BY-SA/GFDL 说明、修改说明和可获得的许可证/来源链接，并检查页面级或媒体级例外。**

原始来源：

- [Wikimedia 官方 English Wiktionary dump 目录](https://dumps.wikimedia.org/enwiktionary/latest/)
- [Wikimedia 官方 dump 许可说明](https://dumps.wikimedia.org/legal.html)
- [Wikimedia 官方可用 dump 类型说明](https://meta.wikimedia.org/wiki/Data_dumps/What%27s_available_for_download/en)
- [Wiktextract 官方仓库 README](https://github.com/tatuylonen/wiktextract)
- [Wiktextract 官方 MIT LICENSE](https://github.com/tatuylonen/wiktextract/blob/master/LICENSE)

## 4. 面向 Engirdle 的落地建议

### 4.1 第一阶段

先做两个互相独立的资源：

- `oewn-2025`：只抽取 lemma、POS、definition、example、synset/source ID 和必要的 forms，验证英英查询、词形查询和多义排序。
- `freedict-eng-zho-2025.11.23`：从官方 TEI 源构建英汉 SQLite，保留英文 headword、POS、英文定义、中文翻译、pronunciation、source/sense 序号。

这样既能验证真正的 `.dictpack` 安装/升级流程，也不会把单一数据源的缺陷误认为查询链路问题。两者可以在 UI 中作为两个 dictionary resource，或在构建阶段按 `source_id` 合并，但不能丢失各自许可证。

### 4.2 第二阶段

- 用 ECDICT 做本地覆盖率对照和文章词汇命中率测试；只选择能够解释来源和许可证的字段进入实验包。
- 若 FreeDict 的 26,660 headwords 不够，再增加 Wiktionary/Wiktextract 的英汉 translation 作为独立补充源，而不是直接覆盖 FreeDict 的义项。
- 用 GCIDE 或 Princeton WordNet 做英英质量/风格对照，观察 Open English WordNet 是否已经满足阅读中的定义长度和现代词覆盖。

### 4.3 统一资源包的最小元数据

每个资源或每个 `source_id` 至少保存：

```text
source_id
upstream_name
upstream_version_or_dump_date
download_url
source_revision_or_checksum
license_name
license_url
copyright_and_attribution
modification_note
extraction_or_filtering_note
```

如果同一个 SQLite 同时包含 OEWN、FreeDict、Wiktionary 或 ECDICT，manifest 应列出数组形式的 sources，并在 entries/senses 上保存 `source_id`。不建议用一个笼统的 `license = MIT/CC` 字段覆盖混合数据。

## 5. 最终排序

| 优先级 | 数据源 | 方向 | 适合用途 | 主要门槛 |
|---|---|---|---|---|
| 1 | Open English WordNet 2025 | 英英 | MVP 英英主源、结构化关系和释义 | 只覆盖主要开放词类；需同时保留 OEWN/Princeton 归属 |
| 1 | FreeDict `eng-zho` 2025.11.23 | 英汉 | MVP 英汉主源、安装器和离线查询验收 | 仅约 26,660 headwords；CC BY-SA 3.0 |
| 2 | Wiktionary + Wiktextract | 英英/英汉 | 长期覆盖和词形/翻译增强 | 解析成本、数据质量和多层许可证合规 |
| 3 | Princeton WordNet 3.0 | 英英 | 小型黄金数据、兼容性测试 | 版本老、覆盖范围有限 |
| 3 | GCIDE 0.54 | 英英 | 传统词典补充/质量对照 | 自有标记解析、GPLv3 义务 |
| 4 | ECDICT | 英汉 | 私人本地覆盖率实验 | 外部来源混杂，MIT 不足以证明全量数据可再分发 |
| 4 | CC-CEDICT | 中文→英文/反查 | 中文词条和拼音补充 | 不是现成英汉；反向索引有歧义；CC BY-SA 3.0 |

