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
2. **英汉主源暂不定案；FreeDict `eng-zho` 不采用。** 官方元数据所称的 English–Chinese 和 26,660 headwords 只说明词典方向与条目数，不能代表中文义项质量。本地官方源包审计显示，89.61% 的条目只有一个顶层翻译组、86.13% 只有一条非空中文翻译，同时 96.17% 的条目含英文 `def`；`take`、`run` 等多义词把一个粗粒度中文词对应到多条英文定义。它与“中文翻译按义项充分展开、结果不混入英英释义”的定位不符，最多保留作解析器 fixture。
3. **MVP 英中源：Chinese Open Wordnet + Open English WordNet。** Chinese Open Wordnet 把中文 lemma 对齐到 Princeton WordNet/CILI 概念，而不是把一条中文翻译粗略挂在多个英文定义外层。本地把官方 `omw-cmn:2.0` 与 OEWN 2025 按 ILI 连接，能对齐 38,878 个中文 synset，且 `bank` 的河岸、银行、储备金、赌本、银行大厦等义项分开。后续产品决策已采纳该组合，并明确只导入中文 lemma、完全相同 ILI 对齐、无覆盖时只显示英英义项；36.16% 的 OEWN synset 中文覆盖仍是已知限制。
4. **私人本地 MVP/质量基线：ECDICT。** 固定提交的基础 CSV 有 770,611 条，99.76% 带中文翻译，`take/run/free/charge/bank/set` 等常见词明显比 FreeDict 丰富，且英文 definition 可整列丢弃；但它没有 sense ID，官方又明确列出大量异质释义来源而未提供逐条 provenance。可支持用户自行导入生成个人本地包，不应由 Engirdle 官方分发。
5. **其他覆盖率候选：Wiktionary dump + Wiktextract**。它能同时抽取英文释义、词性、词形、发音、例句和多语言 translations，最接近长期完整方案；代价是下载/解析/质量筛选成本高，且需要严格处理 Wikimedia 的 CC BY-SA/GFDL、页面内其他来源及归属要求。

### 暂不建议直接作为可再分发 MVP 包

- **ECDICT** 的工程形态和中文覆盖非常强：固定提交下的基础 CSV 有 770,611 条，99.76% 带中文 `translation`，常见多义词的中文也明显比 FreeDict 丰富；英文 `definition` 是独立列，可以在导入时完全丢弃。但它没有 sense ID，中文释义主要按词性压在一个字符串中，且官方自述混合了 WordNet、Wiktionary、Google Cloud Translation、Linguee、Babylon、Urban Dictionary 等众多来源，没有逐条/逐字段 provenance。根目录 MIT `LICENSE` 不足以证明第三方词典内容都已清权。**它适合个人本地导入和覆盖率基准，不适合成为 Engirdle 官方可下载或随应用分发的主 `.dictpack`。**
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

### 3.4 FreeDict `eng-zho`（英汉，不采用；最多作解析器 fixture）

**官方定位与来源真实性**

- FreeDict 官方 API 把 `eng-zho` 列为 English–Chinese，版本 2025.11.23、26,660 headwords，并发布 TEI 源码、StarDict、DICTD 和 SLOB。这个元数据能证明方向、规模与产物格式，不能证明中文义项的粒度和质量。
- 本地归档 [`freedict-eng-zho-2025.11.23.src.tar.xz`](./dictsrc/freedict-eng-zho-2025.11.23.src.tar.xz) 的 SHA-512 是 `25aed0f1…e1fc4c`，与官方 API 的完整校验值一致；以下审计对象是该归档解出的 [`eng-zho.tei`](./dictsrc/eng-zho/eng-zho.tei)，不是来历不明的二次转换文件。
- TEI 头部明确说明它由 WikDict 自动生成，基础数据来自 Wiktionary via DBnary。实际条目是混合结构：英文词头在 `entry/form/orth`，中文翻译在 `cit[@type="trans"][@xml:lang="zh"]/quote`，英文定义则保留在嵌套的 `sense/def`。因此英文 `def` 不是偶发脏字段，而是该发布物的主体结构之一。

**本地全量审计（可复现）**

先运行 `sha512sum .scratch/dictsrc/freedict-eng-zho-2025.11.23.src.tar.xz` 核对官方归档，再用 Python 标准库 `xml.etree.ElementTree` 解析上述 TEI。统计单位定义如下：

- 条目：`text/body/entry`；顶层翻译组：`entry` 的直接子 `sense`；
- 非空中文：后代 `cit[@type="trans"]` 中 `quote` 的合并文本经 `strip()` 后非空；
- 英文定义：后代 `def`。TEI 的 `body` 是 `xml:lang="en"`，这些 `def` 的实际内容也是英文。

| 指标 | 结果 | 对定位的含义 |
|---|---:|---|
| 条目 / 唯一词头 | 26,660 / 24,946 | 官方的 headwords 数与 XML `entry` 数一致，不等于 26,660 个唯一英文词头 |
| 只有 1 个顶层翻译组的条目 | 23,890（89.61%） | 绝大多数词条没有按多个翻译组展开 |
| 中文 `quote` 节点 / 非空节点 | 31,571 / 31,551（99.94% 非空） | 核心问题**不是**中文字段大面积为空 |
| 恰有 1 条非空中文翻译的条目 | 22,963（86.13%） | 每条目的中文翻译中位数也是 1 |
| 英文 `def` 节点 / 含 `def` 的条目 | 34,758 / 25,639（96.17%） | 几乎所有词条都会混入英英定义 |
| 英文定义数多于非空中文翻译数的条目 | 3,655（13.71%） | 一条中文常被用来覆盖多条更细的英文定义 |

复算核心计数的最小脚本如下；它没有依赖第三方 XML 库：

```python
from pathlib import Path
from xml.etree import ElementTree as ET

ns = {"t": "http://www.tei-c.org/ns/1.0"}
root = ET.parse(Path(".scratch/dictsrc/eng-zho/eng-zho.tei")).getroot()
entries = root.findall(".//t:text/t:body/t:entry", ns)
texts = lambda e, p: ["".join(x.itertext()).strip() for x in e.findall(p, ns)]
zh = [texts(e, './/t:cit[@type="trans"]/t:quote') for e in entries]
defs = [texts(e, ".//t:def") for e in entries]
print(len(entries), len({texts(e, "./t:form/t:orth")[0] for e in entries}))
print(sum(len(e.findall("./t:sense", ns)) == 1 for e in entries))
print(sum(len([q for q in qs if q]) == 1 for qs in zh))
print(sum(bool(ds) for ds in defs), sum(len(ds) > len([q for q in qs if q]) for qs, ds in zip(zh, defs)))
```

**义项粒度与数据质量抽样**

- `take` 只有中文“拿”，外层却包含 8 条英文 `def`；`run` 的名词、动词两个条目都只给“跑”，合计对应 5 条英文 `def`。这会让“中文翻译”要么漏义，要么不得不把不等价的多个英文义项挤在同一中文词下。
- 后缀 `free` 的中文是“有”，但英文 `def` 表达的语义是 “without/devoid of”；这是方向性错误，而不是 UI 是否隐藏英文定义就能修复的问题。
- `charge` 等词的中文 `quote` 中出现未清洗的 `[[#`；全库有 46 个 `quote` 含 `[[`、`]]`、`{{`、`}}` 或 `#` 一类残留标记。数量不大，但说明仍需质量过滤。
- 因此，即使构建器完全丢弃 `<def>`，也只能得到一个几乎每词一条、义项对齐不足且带少量模板残留的翻译表；保留 `<def>` 又会直接违背“不混入英英释义”的展示定位。

**下载、许可与最终判断**

- 源码包约 1.6 MiB，StarDict 压缩包约 1.7 MiB，SLOB 约 3.4 MiB（官方 JSON 元数据中的 `size` 字段），技术上很适合测试下载、SHA 校验、解包和 TEI 导入流程。
- 2025.11.23 源 TEI 头部声明 CC BY-SA 3.0，并注明 WikDict/DBnary/Wiktionary 来源。FreeDict 官方文档说明每个词典应以自身 TEI 头部的许可证为准；若保留这个 fixture 或分发派生内容，仍须履行 attribution、Share-Alike 和修改说明等条件。
- **判断：不采用为 Engirdle 的英汉内容源，也不以“后续补覆盖”作为前提；最多留作非生产的 TEI/StarDict 解析器 fixture。是否保留 fixture 还应权衡测试价值与 CC BY-SA 归属成本。**

原始来源：

- [FreeDict 官方下载页](https://freedict.org/zh_cn/downloads/)
- [FreeDict 官方元数据 API](https://freedict.org/freedict-database.json)
- [FreeDict 官方文档：TEI 格式与许可复用](https://freedict.org/zh_cn/documentation/)
- [FreeDict `eng-zho` 2025.11.23 官方源码包](https://download.freedict.org/dictionaries/eng-zho/2025.11.23/freedict-eng-zho-2025.11.23.src.tar.xz)
- [本地官方包解出的 `eng-zho.tei`](./dictsrc/eng-zho/eng-zho.tei)
- [CC BY-SA 3.0 官方法律文本](https://creativecommons.org/licenses/by-sa/3.0/legalcode)

### 3.5 Open Multilingual Wordnet / Chinese Open Wordnet（英汉，优先 PoC 候选）

**为什么比 FreeDict 更贴近定位**

- OMW 官方 v1 页面说明，各语言 wordnet 被规范化并连接到 Princeton WordNet 3.0；中文不是挂在英文词头上的一条粗翻译，而是作为 Chinese Open Wordnet 的 lemma 连接到具体 synset。页面同时明确提醒，不同 wordnet 的大小和准确性差异很大。
- OMW v1 对 Chinese Open Wordnet 的官方统计是 42,312 synsets、61,533 words、79,809 senses，许可证标为 `wordnet`。当前 `wn` 官方索引另提供 `omw-cmn:2.0`（`cmn-Hans`）及其独立下载地址，列出 42,300 synsets；v1 与 v2 数字不能混写成同一版本。
- `omw-cmn:2.0` 的 WN-LMF 头部声明 `<Requires ref="omw-en" version="2.0"/>`，其 synset 带 CILI `ili` 标识。理论上可用 ILI 把 OEWN 的英文 definition/POS 与同一概念下的中文 lemma 组合为按义项对齐的英汉结果，并在 UI 中只展示中文 lemma。

**本地 PoC 审计**

从 `wn` 官方索引指向的 [OMW 2.0 官方发布包](https://github.com/omwn/omw-data/releases/download/v2.0/omw-cmn-2.0.tar.xz) 下载后，以 WN-LMF 的 `LexicalEntry`、`Sense`、`Synset` 计数；本地归档 SHA-256 为 `7d07af60a6ced0cedc4ca114d0b60a796d3f138df0f3be21f6322e53d004e91c`。再将 `omw-cmn:2.0` 与本地官方 OEWN 2025 XML 按 `Synset@ili` 等值连接。结果如下：

| 指标 | 结果 |
|---|---:|
| `omw-cmn:2.0` synsets / lexical entries / senses | 42,300 / 63,339 / 79,797 |
| 中文唯一 `writtenForm` | 61,525 |
| 中文 Definition / Example | 0 / 0 |
| 可连接到 OEWN 2025 的中文 synset | 38,878 / 42,300（91.91%） |
| OEWN 2025 中有中文对齐的 synset | 38,878 / 107,519（36.16%） |
| OEWN 2025 中有中文对齐的 sense | 70,984 / 185,129（38.34%） |
| OEWN 2025 中至少一个 sense 有中文对齐的 lexical entry | 57,550 / 135,969（42.33%） |

这个连接以 `ili` 为键，不是碰巧相同的 PWN offset 字符串。抽样也显示它能保持义项边界：`bank` 的河岸、金融机构、储备金、庄家赌本、银行大厦分别落在不同 synset；`charge` 的费用、电荷、指控也分开。精确英文 lemma 口径下，`take` 的 44 个 OEWN 2025 senses 有 24 个中文对齐，`run` 的 57 个有 25 个；覆盖仍不完整，但明显好于 FreeDict 把“拿”或“跑”粗挂到多条英文定义。

**限制、许可与判断**

- 该数据只有中文 lemma，没有中文定义；它适合“按英文 sense 返回一个或多个中文对译词”，不适合需要中文解释句的产品。部分 lemma 含 `自由+的`、`不受约束+地` 一类形态标记，导入前必须制定可审计的规范化规则，同时保留原值。
- OMW v1 官方页面的已知问题包括：会丢弃未连接到 PWN 的 synset、只保留与 PWN 同义或近义连接的概念、主要关注 lemma 而未完整带入各项目的额外信息。这与本地看到的 36.16% OEWN synset 中文覆盖相符，不能因中文侧 91.91% 可连接就宣称英中覆盖充分。
- `omw-cmn:2.0` 包内许可证允许免费使用、复制、修改和分发软件与数据库，但要求所有副本及修改版保留 Chinese Open Wordnet 的版权、声明和免责声明。与 OEWN 组合发布时，还要分别履行 OEWN CC BY 4.0 及其 Princeton WordNet 上游归属义务。
- **判断：后续产品决策已采纳为 MVP 英中源。** 正式包只保存与 OEWN sense 完全相同 ILI 的中文 lemma，并保留原值与展示规范化值；真实阅读词汇集仍用于持续评估命中率、中文自然度和版本升级稳定性，不用于放宽对齐规则。

原始来源：

- [OMW v1 官方页面、规模、格式与已知问题](https://omwn.org/omw1.html)
- [`wn` 官方可用 wordnet 索引说明](https://github.com/goodmami/wn#open-multilingual-wordnet-omw-collection)
- [`wn` 官方 `omw-cmn` 版本、下载与许可证索引](https://github.com/goodmami/wn/blob/main/wn/index.toml)
- [OMW DATA 2.0 官方 release](https://github.com/omwn/omw-data/releases/tag/v2.0)
- [Chinese Open Wordnet 官方 LICENSE](https://github.com/omwn/omw-data/blob/main/wns/cow/LICENSE)
- [OMW v1 官方数据仓库](https://github.com/omwn/omw-data)

### 3.6 ECDICT（英汉，私人本地候选；不作为可分发主源）

**先澄清名称**

- 本节评估的是 `skywind3000/ECDICT`，即官方 README 所称的 “Free English to Chinese Dictionary Database”。仓库 README 有一处把自身简称写成 `EDICT`，并提到早期输入 `EDictAZ.txt`，但项目名、CSV 和代码均为 **ECDICT**。
- 大写 **EDICT** 通常特指 EDRDG 的日英词典文件；EDRDG 官方文档明确把它定义为 Japanese/English Dictionary File。它不是英汉源，不属于本节候选。结合 Engirdle 的英汉语境，用户所说“评估 EDICT”在此按 ECDICT 处理。

**官方字段与本地固定版本**

- ECDICT 是双解词典：`definition` 存英文释义，`translation` 存中文释义；另有 `word`、`phonetic`、`pos`、Collins/Oxford/考试与词频标记、`exchange` 词形、预留的 `detail`/`audio`。英文和中文至少在列级别分开，构建 Engirdle 包时可以完全不导入 `definition`，不会像 FreeDict 那样必须从嵌套义项里剥离英英内容。
- 本次固定仓库 `master` 提交 `bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b`。基础版 [`ecdict.csv`](./dictsrc/ecdict.csv) 为 65,933,428 bytes，SHA-256 `1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf`；仓库中的 [`stardict.7z`](./dictsrc/stardict.7z) 为 51,577,449 bytes，SHA-256 `b57bf41a24dd4b046f4d7fa0324aba6b56d4f63e5a167bfae26c7344811bba26`。
- `stardict.7z` 实际只含一个 `stardict.csv`，不是 StarDict 的 `.ifo/.idx/.dict` 三件套。解出的 [`stardict.csv`](./dictsrc/stardict.csv) 为 232,668,349 bytes，SHA-256 `88fce01e0a30524192a62e363d47eeb036fa17820d5826121b3b419fd67a3996`。README 把根目录 CSV 称为约 76 万条的“基础版本”，把压缩包称为最新版数据，两者不可混为一个版本。

固定输入的下载/解包命令如下：

```sh
ECDICT_REV=bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b
curl -fL "https://raw.githubusercontent.com/skywind3000/ECDICT/${ECDICT_REV}/ecdict.csv" -o .scratch/dictsrc/ecdict.csv
curl -fL "https://raw.githubusercontent.com/skywind3000/ECDICT/${ECDICT_REV}/stardict.7z" -o .scratch/dictsrc/stardict.7z
sha256sum .scratch/dictsrc/ecdict.csv .scratch/dictsrc/stardict.7z
bsdtar -xf .scratch/dictsrc/stardict.7z -C .scratch/dictsrc
```

**基础 `ecdict.csv` 全量审计（主评估口径）**

用 Python 标准库 `csv.DictReader` 逐行读取 UTF-8 CSV；CSV 内多条释义以两个字节的字面量 `\n` 分隔，必须用 `value.split(r"\n")`，不能用 `splitlines()`。下面的“非空”均指字段经 `strip()` 后非空，“含空格词头”用正则 `\s` 判定：

| 指标 | 结果 | 判断 |
|---|---:|---|
| 数据行 | 770,611 | 与 README 的“约 76 万基础版”一致 |
| 非空中文 `translation` | 768,739（99.76%） | 中文覆盖远高于 FreeDict；其中 767,533 条至少含一个汉字 |
| 非空英文 `definition` | 160,884（20.88%） | 英英内容存在，但能按列干净排除；159,012 条同时有中英双解 |
| 只有英文、无中文 | 1,872（0.24%） | 导入中文包时应过滤 |
| 只有一个 `\n` 逻辑组的中文字段 | 715,740（占有中文条目的 93.11%） | “有中文”不等于“有独立 sense”；组内常以逗号压入多个 gloss |
| `pos` / `phonetic` 非空 | 0 / 218,065（28.30%） | 基础版 `pos` 与 README 描述不一致；不少词性只嵌在 `translation` 文本中 |
| `exchange` 非空 | 96,290（12.50%） | 对常见动词/名词/形容词很有用，但不是全库词形覆盖 |
| `detail` / `audio` 非空 | 1 / 0 | README 也把两列标为待添加，不能依赖 |
| 含空格词头 | 366,599（47.57%） | 短语、专名和长尾组合覆盖广，但必须做内容分层 |
| 中文含 `[网络]` / `[人名]` / `[地名]` | 42,042 / 20,040 / 9,423 | 多类可能重叠；说明“收词量”包含明显的网络释义和专名长尾 |
| Collins / Oxford 标记非空 | 13,633 / 3,461 | 是词级元数据，不是 sense 级来源；再分发权利也需单独审计 |
| BNC / 当代词频为正数 | 45,443 / 42,231 | CSV 用 `0` 表示大量缺失，不能把列非空误算成全量覆盖 |

压缩包内的全量 `stardict.csv` 有 3,402,564 行，其中 `translation` 3,386,028 条、至少含一个汉字的 translation 3,376,001 条、`definition` 177,076 条、`phonetic` 353,134 条、`exchange` 421,570 条，`detail`/`audio` 仍为 1/0。它的词头 60.10% 含空格、中文字段 23.55% 含 `[网络]`，`pos` 仅 52,527 条（1.54%）非空。它扩大了长尾而没有解决 sense 结构与 provenance；因此不能用 340 万总量直接推断阅读查词质量，首轮评估应以更容易审计的基础 CSV 为主。

**义项粒度与常见词抽样**

- `take`、`run`、`free`、`charge`、`bank`、`set` 都只有一行词条，但中文明显比 FreeDict 丰富：例如 `take` 分 `vt./vi./n.` 三组并列“拿、取、抓、接受、采取、乘、需要、花费”等，`run` 分六组，`charge` 覆盖“指控、费用、冲锋、电荷、充电、收费”，`bank` 同时有“银行、堤、岸、库”，`set` 覆盖名词、及物/不及物动词、形容词和计算机用法。
- 这些仍是**词条级字符串**，没有稳定 sense ID，也没有中文 gloss 与英文 definition 的逐义项连接。不能按 `\n` 序号强行配对：`bank` 的四条英文定义没有金融机构义，但中文第一项是“银行”；`free` 的英文主要是名词/动词，中文却从形容词开始；`set` 的英文四条都是名词义，中文还有动词、形容词和计算机义。
- `pos` 在全量版中形如 `n:26/j:1/v:73`，表示语料中的词性比例，不是某条中文义项的 POS。若 UI 需要逐义项排序、来源或例句关联，必须先把 `translation` 的自由文本解析为“词性组 + gloss 列表”，并明确标为推断结构，不能伪造原始 sense 对齐。
- 相比 FreeDict，ECDICT 的优势是中文更丰富、英英列可直接丢弃、常见词 `exchange` 很实用；相比 Chinese Open Wordnet，它的覆盖面大得多，但失去了 synset 级对齐、稳定 ID 和清晰的逐项许可边界。

**词形、短语与离线构建**

- `exchange` 用 `p/d/i/3/r/t/s/0/1` 等代码表示过去式、过去分词、现在分词、第三人称、比较级、最高级、复数和 lemma 关系；六个抽样词都带 exchange。仓库还提供基于 BNC 的 `lemma.en.txt` 和 `LemmaDB`，README 自述其对 BNC 词形查询约有 95% 命中，但该数字没有随本次固定 CSV 提供独立基准报告，应视为上游声明而非本地验收结果。
- 47.57% 的基础版词头含空格，加上 README 的 `stripword` 模糊键，技术上对短语、连字符和空格变体很友好；但专名/地名/网络释义比例意味着构建器应先用真实文章词汇与质量规则裁剪，而不是把整个 66 MB CSV 或 233 MB 全量 CSV 原样下发 Android。
- 官方 `stardict.py` 提供 CSV、SQLite、MySQL 读写和 CSV→SQLite 的转换原语，足够复现“固定 CSV 生成本地 SQLite”。它并不是从所有上游资料重建 ECDICT 的流水线：仓库没有逐来源快照、逐条来源 ID、依赖锁定或一条命令重抓并重建释义，因此只能复现格式转换，不能从原始来源复现当前词典内容。

**许可、更新与最终判断**

- 官方 wiki 明列释义来源包括 EDictAZ/cdict、考试大纲词表、NodeBox、Princeton WordNet、Wiktionary、Wikipedia、CC-CEDICT 反解、TheFreeDictionary、Google Cloud Translation、FOLDOC、Linguee、Babylon、Urban Dictionary、Plain Text English Dictionary 和网友词典，并说明部分不全词条使用英翻中补齐。CSV 没有 source/provenance 字段，仓库也没有把这些来源逐一对应到字段或条目。
- 根目录 MIT 文本用标准措辞授权 “Software and associated documentation files”，但没有明确列出上述第三方数据的各自许可证、授权链或 ECDICT 对其重新许可的依据。尤其 `translation` 本身就是多来源融合结果，所以仅删除 Collins/Oxford 标签或英文 `definition` 不能解决中文数据的来源问题。
- 当前 `master` 提交日期为 2025-03-28，两个 CSV 数据文件最后更新于 2025-01-02；GitHub API 可见的唯一正式 release 是 2017 年的 1.0.28。当前基础/全量 CSV 没有独立语义版本或发布 checksum。实验必须同时固定 Git commit、输入 SHA-256、筛选规则和生成器版本，不能只写“ECDICT latest”。
- **判断：内容实用性上，ECDICT 是目前最值得做私人本地命中率/中文自然度基准的候选，且比 FreeDict 更接近期望；发布合规和 sense 模型上，它不能作为 Engirdle 官方主源。** 可支持用户在 PC 端自行提供 ECDICT CSV、只生成个人本地包；若要由项目提供下载、缓存或裁剪包，必须先获得可审计的数据授权与逐字段 provenance，或改用许可链清晰的数据重建。

原始来源：

- [ECDICT 官方仓库 README（固定提交）](https://github.com/skywind3000/ECDICT/blob/bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b/README.md)
- [ECDICT 官方基础 CSV（固定提交）](https://github.com/skywind3000/ECDICT/blob/bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b/ecdict.csv)
- [ECDICT 官方 `stardict.7z`（固定提交）](https://github.com/skywind3000/ECDICT/blob/bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b/stardict.7z)
- [ECDICT 官方转换代码 `stardict.py`（固定提交）](https://github.com/skywind3000/ECDICT/blob/bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b/stardict.py)
- [ECDICT 官方 wiki：双解释义及来源清单](https://github.com/skywind3000/ECDICT/wiki/%E5%8F%8C%E8%A7%A3%E9%87%8A%E4%B9%89)
- [ECDICT 官方 MIT LICENSE（固定提交）](https://github.com/skywind3000/ECDICT/blob/bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b/LICENSE)
- [ECDICT 官方 1.0.28 release](https://github.com/skywind3000/ECDICT/releases/tag/1.0.28)
- [EDRDG 官方 EDICT 文档（日英词典，用于名称消歧）](https://www.edrdg.org/jmdict/edict_doc_2009.html)

### 3.7 CC-CEDICT（中文→英文，英汉反查补充）

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

### 3.8 Wikimedia English Wiktionary dump + Wiktextract（英英/英汉，长期覆盖方案）

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

先做一个正式资源、一个开放数据英汉 PoC，再加一个只在私人本地运行的质量基线：

- `oewn-2025`：只抽取 lemma、POS、definition、example、synset/source ID 和必要的 forms，验证英英查询、词形查询和多义排序。
- `oewn-2025 + omw-cmn:2.0`：按 CILI/ILI 连接英文 sense 与中文 lemma，验证按义项显示中文对译词、未覆盖义项的降级方式，以及 `+的`/`+地` 等标记的规范化；正式 MVP 决策见 [`mvp/omw_chinese_dictionary_decision.md`](./mvp/omw_chinese_dictionary_decision.md)。
- `ecdict-private`：只接受用户在 PC 端自行提供的固定 CSV，默认仅导入 `translation`、必要的 `exchange` 和可解释的基础字段，生成不上传、不共享的个人本地包；用它衡量 OMW/Wiktionary 在真实阅读词汇上的中文覆盖与自然度差距。它不是 Engirdle 的正式数据依赖，也不进入官方资源目录。

FreeDict `eng-zho` 不进入内容验收；若确有覆盖 TEI/StarDict 导入器的测试需要，只截取最小、许可证信息完整的 fixture，避免把“能解析”误判为“内容可用”。`.dictpack` 安装/升级流程可用 OEWN 或项目自建黄金数据验证，不依赖 FreeDict。

### 4.2 第二阶段

- 在同一批真实阅读词汇上比较 Chinese Open Wordnet、Wiktionary/Wiktextract translations 和私人本地 ECDICT 的词头命中率、sense 命中率、中文自然度、噪声率与许可证可追溯性；在数据出来前不指定可分发英汉主源。
- ECDICT 始终只作 user-supplied/private comparator；即使只选择部分字段，也不能在没有来源授权证据时进入正式包。Wiktionary 路线保留 page/sense/dump 日期；FreeDict 不作为它们的基线或补充层。
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

如果同一个 SQLite 同时包含 OEWN、Chinese Open Wordnet、Wiktionary 或 ECDICT，manifest 应列出数组形式的 sources，并在 entries/senses 上保存 `source_id`。不建议用一个笼统的 `license = MIT/CC` 字段覆盖混合数据。PoC 也应记录 CILI 版本和连接规则，避免未来升级后无法复现义项映射。

## 5. 最终排序（英汉主源未定案）

| 优先级 | 数据源 | 方向 | 适合用途 | 主要门槛 |
|---|---|---|---|---|
| 1 | Open English WordNet 2025 | 英英 | MVP 英英主源、结构化关系和释义 | 只覆盖主要开放词类；需同时保留 OEWN/Princeton 归属 |
| MVP 2 | Chinese Open Wordnet `omw-cmn:2.0` + OEWN 2025 | 按 synset 对齐的英→中 | 正式英中 lemma 来源 | 仅中文 lemma、无中文定义；OEWN synset 中文覆盖 36.16%；需清洗形态标记并持续验证自然度 |
| 2 | Wiktionary + Wiktextract | 英英/英汉 | 长期覆盖和词形/翻译增强 | 解析成本、数据质量和多层许可证合规 |
| 3 | Princeton WordNet 3.0 | 英英 | 小型黄金数据、兼容性测试 | 版本老、覆盖范围有限 |
| 3 | GCIDE 0.54 | 英英 | 传统词典补充/质量对照 | 自有标记解析、GPLv3 义务 |
| 私有 PoC 1 | ECDICT | 英汉 | user-supplied 私人本地主词典、开放候选的高覆盖质量基线 | 无 sense ID；外部来源混杂，MIT 不足以证明全量数据可再分发；不得进入官方包 |
| 4 | CC-CEDICT | 中文→英文/反查 | 中文词条和拼音补充 | 不是现成英汉；反向索引有歧义；CC BY-SA 3.0 |
| 不采用 | FreeDict `eng-zho` 2025.11.23 | 英汉+英英混合 | 最多作解析器 fixture | 中文义项粒度/对齐质量不符合定位；96.17% 条目含英文 `def`；CC BY-SA 3.0 |
