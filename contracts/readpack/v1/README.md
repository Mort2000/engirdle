# Readpack v1

Readpack v1 是一个 ZIP 容器，用于从 PC 向移动端交付不可变的文章、句译、音频和归属信息。

## 逻辑布局

ZIP 必须且只能包含四个普通文件：

```text
manifest.json
article.json
attribution.json
audio/article.m4a
```

`manifest.json` 是信封，不得把自己放入 `files`。`files` 必须一一声明另外三个文件。ZIP 中不允许显式目录项、额外文件、空路径、反斜杠、绝对路径、`.`/`..` 分量、规范化后重复路径、链接、设备文件或加密条目。

ZIP 采用的压缩算法只是容器实现细节；导入器必须至少支持 `stored` 和 `deflate`。不得依赖 ZIP 条目顺序、时间戳、主机平台或压缩级别。

## 数据规则

- `article_id` 和 `package_id` 是 UUID；`block_id` 和 `sentence_id` 是修订内唯一的不透明字符串，消费者不得解析其格式。
- `revision` 和 `artifact_revision` 从 1 开始单调递增。
- 块和句子的 `order` 均从 0 开始，在各自所属数组中必须连续且与数组位置一致。每块至少有一句。
- MVP 发布 profile 要求每句都有非空 `translation_zh` 和完整音频边界。Schema 保留译文和时间边界的可选性，以表达 v1 数据模型；PC 发布和移动导入的语义校验仍必须拒绝缺失项。
- 句子样本区间为 `[audio_start_sample, audio_end_sample)`，不包含句后停顿。区间必须非空、单调、不重叠并且不超过音频。
- 毫秒边界由样本边界一次换算：开始使用 `floor(start_sample * 1000 / sample_rate_hz)`，结束使用 `ceil(end_sample * 1000 / sample_rate_hz)`。
- manifest、article 和 attribution 的文章 ID/修订必须完全一致；manifest 的音频路径必须与音频文件描述符一致。
- `attribution.json` 中的 `resource_id` 必须唯一。未知和不适用的来源、版本、许可或修改信息必须分别使用 `unknown` 或 `not_applicable`，不得伪造占位值。

## 资源上限

v1 默认导入上限如下。实现可以配置更严格的上限，不得无界解压。

| 项目 | 上限 |
|---|---:|
| ZIP 文件 | 512 MiB |
| 展开后总量 | 1 GiB |
| ZIP 条目数 | 64（v1 布局实际必须为 4） |
| 单条目 | 1 GiB |
| 规范化相对路径 | 240 个 Unicode 码点 |

导入器必须先检查中央目录，再在流式解压时独立计数，不得只信任 ZIP 声明值。

## 目录

- `schema/`：三个 JSON Schema 2020-12 文件。
- `examples/minimal/`：黄金包的展开后内容；音频是不含语音或模型输出的短静音。
- `fixtures/valid/`：应被完整校验器接受的 ZIP。
- `fixtures/invalid/`：应在写入最终目录前被拒绝的最小 ZIP。具体预期见 [`fixtures/README.md`](./fixtures/README.md)。

兼容性语义见 [`COMPATIBILITY.md`](./COMPATIBILITY.md)。
