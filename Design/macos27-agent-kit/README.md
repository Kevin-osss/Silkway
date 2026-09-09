# Apple macOS 27 UI Kit：Agent 查阅包

这份资料包把用户提供的官方 `.sketch` 文件转换成可搜索的组件索引、样式数据、原文摘取和图片参考。组件内容直接来自文件；查阅工具和执行规则由本次任务编写，不能当成 Apple 发布的额外规范。

**先读 [AGENT_RULES.md](AGENT_RULES.md)，再按当前页面需要检索。不要一次把整个库塞进上下文。**

## 文件来源与范围

- 原文件：`Apple macOS 27 UI Kit.sketch`，未修改。
- Kit 内部 Change Log 最新条目：**27.0.1，June 23, 2026**。版本原文见 [Change Log](notes/change-log-3d034c55.md)。
- 来源校验：原文件路径、完整 SHA-256、Sketch 应用版本和文件格式版本见 [manifest.json](manifest.json)。这些版本概念分开记录。
- [Apple 官方资源页](https://developer.apple.com/design/resources/) · [Sketch 官方库](https://www.sketch.com/s/57153a31-3379-4737-8ac6-dbfd6525f052)

| 提取内容 | 数量 | 入口 |
|---|---:|---|
| 页面 | 37 | `catalog/pages.json` |
| Symbol 定义，含尺寸、外观与状态变体 | 4,679 | [组件目录](catalog/INDEX.md) |
| 共享文字样式 | 67 | `tokens/text-styles.json` |
| 共享图层样式 | 285 | `tokens/layer-styles.json` |
| 本地颜色变量 | 110 | `tokens/colors.json` |
| 外部库缓存颜色变量 | 2 | 同上，标记为 `foreign_cached` |
| Symbol 外的页面元素 | 592 | `catalog/page-elements.jsonl` |
| Symbol 外的文字图层 | 251 | `notes/page-text.jsonl` 与各页 Markdown |
| 代表组件原生导出 PNG | 18 | [预览画廊](visuals/index.html) |

4,679 是包括变体在内的 Symbol 数量，不能理解为 4,679 种独立控件或 SDK API。

## 给 Agent 的最短指令

把本文件夹放在项目的 `design/macos27-agent-kit/`，并在项目给 Agent 的长期说明或本次任务中加入：

```text
本项目界面以 design/macos27-agent-kit/ 中的官方资源快照为依据。
开始 UI 工作前，读取该目录的 README.md 和 AGENT_RULES.md。
先检索相关组件，再读取精确 ID 的详情和图片，最后设计与实现。
关键控件须记录 Kit 组件 ID、使用状态和经官方文档核实的原生 API。
不得把自行猜测的尺寸、颜色、组件或 API 写成 Apple 规范。
交付时提供组件依据表、实际运行截图和未验证项。
```

长期说明必须指向项目内实际存在的目录。只有把 ZIP 附在对话中，并不保证每次任务都会自动使用它。

## 按需查阅

脚本只用 Python 标准库，支持 Python 3.9+。下面命令在资料包目录执行。机器不方便运行脚本时，先读 `catalog/INDEX.md` 中的分类 Markdown，再查看对应样式 JSON。

```sh
# 找按钮的某个外观和尺寸范围；多个关键词为“同时包含”
python3 scripts/kit.py search --category Buttons 'Light' 'Bordered Default/' '3 Rg' --limit 5

# 查一个已经核实存在的按钮：可用 layer ID 或 symbol ID
python3 scripts/kit.py show B62E926D-1454-4CBA-96B5-9A8BC7A66498

# 保留全部子层、覆盖项、布局约束与原始属性，不截断
python3 scripts/kit.py show B62E926D-1454-4CBA-96B5-9A8BC7A66498 --raw

# 查颜色、文字样式或图层样式
python3 scripts/kit.py search --scope colors 'Label' --limit 5
python3 scripts/kit.py search --scope text-styles 'Body' --limit 5
python3 scripts/kit.py show '06 Body/Default'
python3 scripts/kit.py search --scope layer-styles 'Glass' --limit 5

# 材质页中的示例可能是普通图层，不一定是 Symbol
python3 scripts/kit.py search --scope page-elements --category Materials --limit 5
python3 scripts/kit.py notes 'Change Log' --limit 20

# 检查提取结果、原始 JSON 哈希和索引完整性
python3 scripts/kit.py verify
```

`show` 默认返回深度为 1 的图层摘要，并明确标记未展开的字段与子层。需要内部结构时使用 `--depth 2` 或 `--raw`；不能把摘要省略的内容理解为源文件没有。

检索结果的原始名称、`name_segments` 与样本 frame 均保留。`category` 是移除私用区图标字符后的检索辅助名称，不是新的官方组件名。6 组名称重复，脚本不会静默选择同名项，应使用 ID 消歧。

## 看见组件

打开 [visuals/index.html](visuals/index.html) 可查看按钮、侧栏、文本框、搜索框、工具栏按钮组、窗口和警告的浅深两种外观。18 个预览均由本机官方 Sketch CLI 原生渲染，并已逐张查看。

每张图片的原始名称、page/layer/symbol ID、样本 frame 与实际图片像素尺寸见 `visuals/manifest.json`。图片可能包含阴影或出界内容，因此图片像素宽高不一定等于 frame 乘以导出倍数。画廊背景仅为展示选择。

继续按需导出其他组件需要原始 `.sketch` 文件和可用的 Sketch：

```sh
python3 scripts/kit.py render B62E926D-1454-4CBA-96B5-9A8BC7A66498 \
  --source '/Users/kevinwang/Downloads/Apple macOS 27 UI Kit.sketch' \
  --output ./additional-previews
```

脚本会核对原文件 SHA-256，使用官方 `sketchtool export layers`，不进行图片仿画。输出仍须目视检查。查看和检索本资料包不需要安装 Sketch。

## 原始证据与已知缺口

`evidence/source-json.zip` 保留未经修改的 `document.json`、`meta.json` 及全部 37 页 JSON。每个组件/样式都能通过 ZIP 成员路径和 JSON Pointer 定位到原记录。原始嵌套 Symbol、文字属性区间、overrideValues、Flex 布局、padding、sizing、蒙版和资源引用均保存在原始证据中。

原文件中的图片和字体二进制未重复打包；完整原文件仍是继续渲染的依据。原始内嵌封面已保留为 `evidence/document-preview.png`，它只代表最后编辑页的预览，不能代替整个库的视觉检查。

独立检查与提取器均发现：

- 普通 Symbol 实例引用均可在文件内解析。
- 44 个非空 Symbol 替换 override 指向 5 个未找到的目标 ID。
- 118 处颜色引用指向 15 个未找到的 swatch 定义；对应颜色记录中仍可能保留 RGBA。
- 这些缺口已写入 `evidence/reference-audit.json`，没有猜补或修复。它们可能涉及历史或未生效的覆盖项，不能仅据此断言渲染损坏。

## 从设计资源到真正的 Mac 应用

本文件能证明“Kit 中有什么”，不能单独证明“某个公开 API 如何使用”。实现时继续核对 [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/) 和对应 SwiftUI/AppKit 官方 API 文档。

- Sketch 的示例窗口大小、图层 x/y 和文字内容不自动成为产品布局要求。
- 静态 RGBA、字体 PostScript 名称、阴影和模糊叠层不自动等价于运行时系统颜色、字体或材质 API。
- 某些圆角字段含极大的内部数值；不要直接抄成代码里的圆角半径。
- 私用区字符保留原样，不自动猜成 SF Symbols 的可编程名称。
- 优先使用系统原生组件和语义样式；自定义业务布局属于项目决定，应单独记录。
- Sketch 预览不是真实 macOS 27 应用运行截图，最终仍需运行应用验证。

Sketch 的 ZIP + JSON 文件结构和 CLI 导出方式分别见 [官方文件格式说明](https://developer.sketch.com/file-format/)与[官方导出文档](https://developer.sketch.com/cli/export-assets)。
