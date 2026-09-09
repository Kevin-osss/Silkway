# 官方 Sketch 组件原生导出预览

本目录包含 18 个代表性组件的 2× PNG，以及 `manifest.json` 来源清单。源文件未被修改，图片仅由官方 Sketch `sketchtool export layers` 渲染，没有仿画。

打开 `index.html` 可对照查看浅色与深色版本。HTML 的浅色和深色画布仅为方便查看透明 PNG 而选，不是从 UI Kit 提取的规范值。PNG 文件名使用原始 layer ID，来源 page ID、symbol ID、原名、frame、像素尺寸、导出环境和限制均保留在 `manifest.json`。

导出范围：普通/默认按钮、侧栏示例、空文本框/输入中状态、搜索框、工具栏三按钮组、带侧栏完整窗口、警告；各浅色、深色一份。其他组件应根据主索引定位，并从源文件按 layer ID 导出。

## 核验与限制

- 使用 Sketch CLI 2026.3 (233959)。源文件 metadata 为 Sketch 2026.2 (231037)；18 个导出均成功，stderr 为空。
- 已逐张打开 18 个 PNG 并核对尺寸；未发现空白导出或明显结构损坏。源设计本身的空内容区、长侧栏裁切和占位图形保持原样。
- 保留原始 alpha。部分图片查看器若忽略 alpha，可能把半透明白色描边/选中背景显示成纯白；以支持透明度合成的浏览器画廊查看。
- CLI 没有报告缺字/缺字体；可见文本和常用图标已目视检查，但没有逐一核验整个 Kit 的所有字体或字形。
- 这是 Sketch 渲染结果，不能代替真实 macOS 27 应用截图、材质背景互动和无障碍检查。
- 工具栏圆形占位字符在源图层中为名为 Symbol 的 U+1004DE；本包未臆测其可编程 SF Symbols 名称。

## 再导出一个组件

```sh
/Applications/Sketch.app/Contents/MacOS/sketchtool export layers \
  '/Users/kevinwang/Downloads/Apple macOS 27 UI Kit.sketch' \
  --item=B62E926D-1454-4CBA-96B5-9A8BC7A66498 \
  --output=./preview --formats=png --scales=2 --use-id-for-name=YES
```

命令中的路径按本机位置替换；`--item` 使用主索引记录的 layer ID，而非猜测组件名称。
