# Silkway 设计资产

Claude Design 产出的原型与设计规范。**本目录是设计事实来源**，手册第 5 节的 UI 规范由此提取，两者冲突时以本目录为准。

---

## 目录结构

```
Design/
├── prototype/
│   ├── Silkway.dc.html      可交互原型（Claude Design canvas 文档）
│   └── support.js           Claude Design 运行时，非项目代码，勿修改
├── spec/
│   └── UI_Design_Requirements.md   UI 设计需求文档
├── assets/                  ← 正式图标资产（已验证，见下）
│   ├── icon/                应用图标 7 档 PNG（16–1024）+ 1024 SVG 源文件
│   ├── menubar/             菜单栏图标 PDF（连/断两态，纯黑+alpha，已验证）
│   │                        + 对应 SVG 源文件
│   └── preview.html         各尺寸预览页
└── references/
    ├── design-doc-icon-spec.png    图标规格截图
    ├── design-doc-tokens.png       配色 Token 截图
    ├── pasted-*.png                设计过程参考图
    └── deprecated/                 已废弃资产，勿使用
```

## 图标资产（assets/）

**验证状态（2026-09-02，sips + 像素级采样）**：

| 项目 | 规格要求 | 实测 | 结论 |
|------|---------|------|------|
| 应用图标 PNG | 7 档 16–1024，sRGB + alpha | 全部符合 | ✅ |
| 四角透明 | 4 角 alpha=0（圆角烘焙） | 16/32/64/128/256/512/1024 全部通过 | ✅ |
| 菜单栏 PDF | 16×16pt，纯黑 + alpha | MediaBox 16×16pt，非透明像素 0 偏色 | ✅ |
| SVG 源文件 | 1024 图标 + 16 菜单栏 | 3 份齐全 | ✅ |

菜单栏 PDF 是纯黑 + alpha，可直接设 `NSImage.isTemplate = true` 用于菜单栏。

## 接线状态（App 内使用）

| 资产 | 接入位置 | 方式 |
|------|---------|------|
| 应用图标 | `Resources/Assets.xcassets/AppIcon.appiconset/` | 10 槽位 Contents.json，7 张 PNG 复用 |
| 菜单栏 PDF | `Resources/Silkway-menubar-{connected,disconnected}.pdf` | `SilkwayApp.swift` 加载，`isTemplate = true`，断态加斜杠 |

⚠️ `AppIcon.appiconset/Contents.json` 含真实图标，**重新运行 `generate-xcodeproj.py` 不会覆盖它**（脚本已改为只在无 filename 字段时写占位）。
图标源文件改动后需手动同步：`cp Design/assets/icon/*.png Silkway/Resources/Assets.xcassets/AppIcon.appiconset/` 并按尺寸重命名。

## 如何查看原型

```bash
open Design/prototype/Silkway.dc.html
```

原型是**可交互**的：电源键可切换连接态、「批量测速」有进度动画、策略组可展开、设置面板 7 个 Tab 可切换。

包含 3 个分区：

| 分区 | 内容 |
|------|------|
| 1a | 深色模式 · 菜单栏弹窗 + 设置面板（P0） |
| 1b / 1c | 浅色模式 · 同版式适配 |
| 03 | 品牌标识 · 配色 Token · SF Symbols · 交互流程 |

---

## 已定案的品牌决策

| 项 | 结论 |
|----|------|
| 产品名 | **Silkway（丝路）**，原型文档中的 "SingBoxer" 为历史遗留，已更正 |
| 图标 | **环绕地球的轨道箭头** |
| 菜单栏图标 | **地球轨道单色简化版**（自定义 template image）；原 `shield.*` SF Symbol 方案已废弃 |
| 吉祥物 | **已废弃**（金毛犬形象），存档于 `references/deprecated/` |
| 强调色 | **跟随系统** `Color.accentColor`，不锁定品牌蓝 |

### App 图标规格

- 造型：环绕地球的轨道箭头 —— 一条线路连通世界各地
- 容器：squircle，圆角半径 24%
- 底色：160° 线性渐变 `#4AA8FF → #0A4FB0`
- 图形留白：6%
- 大尺寸（1024/512/256）：保留经线与轨道后段，半透明表示穿行球体背面
- 小尺寸（64/32）：只留赤道线并加粗描边，保证辨识度
- 菜单栏：单色 template image，随系统自动反色

---

## ⚠️ 待补：正式图标资产缺失

`assets/` 目录当前为空。**采用的地球轨道图标尚无任何导出文件** —— 它只存在于 `prototype/Silkway.dc.html` 的渲染结果和 `references/design-doc-icon-spec.png` 截图中。

进入 P0 任务 1（项目骨架）前需产出：

- [ ] `AppIcon` PNG 切图 7 个尺寸：1024 / 512 / 256 / 128 / 64 / 32 / 16
      （sRGB、带 alpha、squircle 圆角与 6% 留白烘焙入图，四角透明）
- [ ] `AppIcon` 1024×1024 SVG 矢量源文件（为日后 Icon Composer 留后路）
- [ ] 菜单栏 template image：16×16pt PDF 矢量，纯黑 + alpha，简化图形（只留赤道线加粗描边）
- [ ] 菜单栏断开态：同上，图形叠加一道斜杠

菜单栏图标注意：设置 `NSImage.isTemplate = true` 后系统**只使用 alpha 通道**，RGB 被忽略，因此纯白或纯黑填充均可。但**必须设置该标志**，否则浅色菜单栏下白色图标不可见。

---

## 与手册的关系

| 内容 | 位置 |
|------|------|
| 配色 Token、SF Symbols、延迟色阶 | 手册第 5 节（已从本目录提取） |
| 信息架构、交互细节、竞品参考 | `spec/UI_Design_Requirements.md` |
| 视觉还原基准 | `prototype/Silkway.dc.html` |
