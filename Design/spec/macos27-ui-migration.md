# Silkway macOS 27 UI 迁移方案

> **目的**：将 Silkway 的自定义 UI 逐步迁移到 macOS 27 原生控件和系统样式，
> 优先使用公开 SwiftUI/AppKit API，不修改业务逻辑。
>
> **依据**：`Design/macos27-agent-kit/`（Apple macOS 27 UI Kit 27.0.1, June 23, 2026，
> 从官方 Sketch 文件提取，SHA-256: `8f83805217d979dc560d008fce66c1c77014f631cccff8978f31baf1d7ef3b28`）+
> Apple HIG / SwiftUI 官方文档。
>
> **关键规则**：Kit 是设计资产快照，不是 API 文档。
> 每个控件的 SwiftUI 映射都标注了核实状态；找不到映射的明确标注，不凭空补造。

---

## 1. 现状审计

### 1.1 页面 / 窗口 / 导航结构

| 窗口 | 当前实现 | 结构 |
|---|---|---|
| **菜单栏弹窗** | `MenuBarExtra` `.window` 样式 | 状态头 → 快捷控制 → 策略组列表 → 底部操作 |
| **设置窗口** | `Settings` scene + `TabView` | 7 个 Tab：通用/订阅/代理节点/路由规则/DNS/连接日志/关于 |
| **添加订阅/节点** | `.sheet` 弹窗 | 内嵌在 SubscriptionView / ProxyView 中 |

### 1.2 SDK 与运行环境

| 项 | 值 | 说明 |
|---|---|---|
| 最低支持系统 | **macOS 14.0** | `MACOSX_DEPLOYMENT_TARGET` 写死 |
| 当前系统 | **macOS 27.0** | 开发机实测 |
| Xcode | **27.0 (27A5228h)** | beta，含 Liquid Glass 组件 |
| Swift | **6.0** | 严格并发检查 |
| 测试环境 | `swift test` (SwiftPM) + `xcodebuild` | 55 项测试，另有一套真实 sing-box 校验 |

### 1.3 字体、颜色、材质

| 层 | 当前做法 | 来源 |
|---|---|---|
| **颜色** | `ColorToken` 枚举 | 自定义：系统语义色 + 锁定状态色 |
| **字体** | `Text(...)` 默认系统字体 | 部分自绘行 `.font(.system(size: 12))` |
| **材质** | `.ultraThinMaterial`（弹窗背景） | SwiftUI 系统材质，正确用法 |
| **圆角** | `RoundedRectangle(cornerRadius:)` 6-7pt | 自绘分段控件/搜索框背景 |
| **阴影** | `shadow(radius: 4, y: 2)`（AboutView 图标） | 系统默认 |

### 1.4 自定义控件（迁移重点）

| 控件 | 位置 | 当前实现 | 迁移目标 |
|---|---|---|---|
| **分段控件**（接管方式/出站模式） | `QuickControls.swift` | 自绘 HStack + 圆角背景 | **`Picker(.segmented)`** 或 `NSSegmentedControl` |
| **搜索框** | `ProxyView.swift` (SearchField) | 自绘 RoundedRectangle + 放大镜图标 | **`SearchField`**（SwiftUI 系统控件） |
| **策略组行** | `GroupRow.swift` | 自绘两字母角标 + 文本 + 箭头 | 保留（业务控件，非标准控件替代） |
| **节点行** | `MemberNodeRow` / `NodeRow`（已删） | 自绘 HStack | 保留（业务控件） |
| **电源按钮** | `StatusHeader.swift` | 自绘 Circle + power SF Symbol | 保留（品牌视觉，非标准开关） |
| **徽章/标签** | `LatencyBadge` / `ProtocolTag` | 自绘圆角背景 | 保留（业务视觉语义） |

### 1.5 业务行为、状态绑定、快捷键

| 行为 | 位置 | 状态 |
|---|---|---|
| 订阅深链 | `ActionFooter` → `@AppStorage("silkway.settings.tab")` | ✅ 保留 |
| 弹窗确认快捷键 | `.keyboardShortcut(.defaultAction / .cancelAction)` | ✅ 保留 |
| 菜单栏图标状态切换 | `SilkwayApp.swift` `menubarIcon` | ✅ 保留 |
| 测速进度 | `TestSpeedButton` + `ProgressView` | ✅ 保留 |

---

## 2. 旧设计要求分类

### 2.1 业务约束（继续保留）

| 约束 | 依据 | 位置 |
|---|---|---|
| 菜单栏弹窗宽 340px，高度自适应 | 手册 5.1 | `MenuBarView` |
| 设置窗口 TabView + Sidebar 样式 | 手册 5.2 | `SettingsView` |
| 状态色锁定固定值（不跟随系统强调色） | 手册 5.3 + 设计需求 5.1 | `ColorToken` |
| 延迟色阶（<200 绿 / 200-500 黄 / >500 红） | 手册 5.4 | `LatencyBadge` |
| 浅色模式「黄」用棕橙 #B25000 | 手册 5.4 警告 | `ColorToken.warning` |
| 菜单栏图标双态（连/断 + 斜杠） | 手册 5.6 | `SilkwayApp` |
| App 图标规格（squircle / 轨道箭头 / 留白 6%） | 手册 5.6 | Assets.xcassets |
| 深色优先设计 | 设计需求 §2 | 整体 |

### 2.2 视觉规则（与 Kit 对照，需替换）

| 旧规则 | Kit 依据 | 迁移方案 | 影响 |
|---|---|---|---|
| 弹窗背景 `.ultraThinMaterial` | `Liquid Glass/Dark/Menus` 层样式 | **改用系统菜单栏弹窗默认材质**（`.menuBarExtraStyle(.window)` 由系统决定，不手动覆盖背景） | 弹窗视觉与系统 WiFi/蓝牙面板一致 |
| 自绘分段控件（接管/出站模式） | `Segmented Controls/Dark/Content Area/Duo & Trio` | **`Picker(.segmented)`**（SwiftUI 原生，自动适配 Liquid Glass） | 移除自绘圆角和透明度逻辑 |
| 自绘搜索框 | `Search Fields/Dark/3 Rg` | **`TextField(...).textFieldStyle(.plain)` 外裹系统搜索框**，或直接 `SearchField`（AppKit） | 移除自绘 RoundedRectangle 背景 |
| 自绘 Toggle 样式 | `Toggles - Switches/Dark/Content Area` | **系统 `Toggle(.switch)`**（已在用，无需改） | 无变化 |
| 自绘列表行圆角背景 | `Forms/Rows - Leading` | **保留**（业务控件，Kit 无直接映射） | 无变化 |

### 2.3 混合约束（信息密度/分组/操作位置，逐条说明影响）

| 约束 | 现状 | 影响 |
|---|---|---|
| 弹窗信息密度 | 状态头 + 快捷控制 + 策略组 + 底部操作 | **保留**。快捷控制是设计评审决定的，不是 Kit 强制 |
| 策略组展开/二级页 | 二级选择页（不内联展开） | **保留**。这是 Silkway 的业务决定，Kit 菜单样式不涵盖此交互 |
| 底部操作区 | 测速/更新订阅/连接日志/设置/退出 | **保留**。操作位置经设计评审定稿 |
| 设置页 Tab 顺序 | 通用 → 订阅 → 代理节点 → 路由规则 → DNS → 连接日志 → 关于 | **保留**。信息架构不因 Kit 改变 |

---

## 3. 迁移表（第一阶段：菜单栏弹窗）

> 只覆盖菜单栏弹窗（代表性主窗口）。设置窗口和其他页面在第二阶段推广。

| 现有界面元素 | 保留行为 | Kit 精确名称/ID | SwiftUI/AppKit API | 依据类别 | 受影响文件 | 验证方法 |
|---|---|---|---|---|---|---|
| 弹窗整体背景 | 高度自适应、点外关闭 | `Liquid Glass/Dark/Menus` (layer style) | **系统默认**：`.menuBarExtraStyle(.window)` 不手动覆盖背景 | 系统默认 | `MenuBarView.swift` | 运行 App，深浅模式截图对比系统 WiFi 弹窗 |
| 接管方式分段控件（系统代理/TUN） | 互斥切换、切换重启 sing-box | `Segmented Controls/Dark/Content Area/Duo/3 Rg` (ID: `42577747-9DF5-47AA-BD4B-48DEC8D76EAA`) | **`Picker(...).pickerStyle(.segmented)`** | 官方资产 + HIG | `QuickControls.swift` | 运行 App，点选验证重启逻辑不破坏 |
| 出站模式分段控件（全局/规则/直连） | 热切切换模式 | `Segmented Controls/Dark/Content Area/Trio/3 Rg` (ID: `A1B2C3D4-...`，实际 ID 需检索) | **`Picker(...).pickerStyle(.segmented)`** | 官方资产 + HIG | `QuickControls.swift` | 运行 App，切换模式验证 API 调用 |
| 当前配置下拉菜单 | 列出 profile、切换重启 | `Pop-up and Pull-down Buttons/Dark/...` (需检索) | **`Menu`（SwiftUI）+ `.menuStyle(.borderlessButton)`** | 官方资产 + HIG | `QuickControls.swift` | 运行 App，切换配置验证 restart |
| 策略组行（GroupRow） | 点击进入二级页 | `Forms/Rows - Leading`（无直接映射，业务控件） | 保留自绘 | 项目决定 | `GroupRow.swift` | 运行 App，点击展开二级页 |
| 节点行（MemberNodeRow） | 选中打勾、延迟显示 | 同上 | 保留自绘 | 项目决定 | `GroupDetailView.swift` | 运行 App，选节点验证 |
| 电源按钮 | 连接脉冲动画 | 无映射（品牌视觉） | 保留自绘 | 项目决定 | `StatusHeader.swift` | 运行 App，连接/断开验证动画 |
| 底部操作区 | 测速/更新/连接日志/设置/退出 | `Menus/Dark/Mini/Menu without Selection/Items` | 保留自绘 | 项目决定 | `ActionFooter.swift` | 运行 App，各按钮功能验证 |
| 弹窗圆角 | 系统默认 | 无（系统决定） | 不手动设置 | 系统默认 | `MenuBarView.swift` | 运行 App 截图 |

### 3.1 找不到映射的组件

| 元素 | 原因 | 处理 |
|---|---|---|
| 策略组行的两字母角标 | Kit 无此控件，业务自定义 | 保留自绘，标注「项目决定」 |
| 节点行的协议标签 | 同上 | 保留 |
| 延迟颜色徽章 | 同上 | 保留 |
| 电源按钮的脉冲光环动画 | Kit 无此动画规格 | 保留 |

---

## 4. 分批计划

### 第一阶段（本次）：菜单栏弹窗迁移

**代表性窗口**：`MenuBarView`（菜单栏弹窗，宽 340px）

**修改点**：
1. **移除 `.ultraThinMaterial` 背景覆盖**，让系统决定弹窗材质（macOS 27 的 Liquid Glass）
2. **QuickControls 分段控件改用 `Picker(.segmented)`**：
   - 接管方式：`Picker` 绑定 `AppConfig.tunEnabled`（或派生 Bool）
   - 出站模式：`Picker` 绑定 `SingBoxManager.mode`（或派生 ProxyMode）
3. **验证切换逻辑不破坏**：切换接管方式/TUN 时仍触发重启；切换模式时仍调用 API
4. **深浅模式截图对比**：运行 App 分别在深/浅模式下截图，与系统 WiFi 弹窗对比

**不修改的部分**：
- 状态头（StatusHeader）
- 策略组列表（GroupList / GroupRow / GroupDetailView）
- 底部操作区（ActionFooter）
- 所有业务逻辑（配置存储、API 调用、重启流程）

**预期影响**：
- 弹窗视觉与系统面板一致（Liquid Glass 材质）
- 分段控件获得系统焦点/禁用/键盘导航支持
- 减少自绘代码，降低维护成本

### 第二阶段（后续）：设置窗口迁移

- 设置窗口 TabView 已是系统样式，无需迁移
- 表单行（GeneralView / SubscriptionView 等）已是 `Form(.grouped)`，无需迁移
- 重点：搜索框（ProxyView 的 SearchField）改用系统搜索框样式
- 重点：AddSubscriptionSheet / AddNodeSheet 的按钮样式统一为系统按钮

### 第三阶段（后续）：细节打磨

- AboutView 图标阴影（如与系统不一致）
- 连接日志页（ConnectionView）的图表样式
- 所有页面的空/错/加载状态统一为系统样式（`ContentUnavailableView` 已在用）

---

## 5. 首批具体修改方案

### 5.1 修改点 1：弹窗背景移除材质覆盖

**文件**：`Silkway/Views/MenuBar/MenuBarView.swift:50`

**现状**：
```swift
.background(.ultraThinMaterial)
```

**改为**：
```swift
// 移除手动背景覆盖，让系统决定菜单栏弹窗材质（macOS 27 Liquid Glass）
```

**依据**：
- Kit `Liquid Glass/Dark/Menus` 层样式证实菜单类弹窗使用 Liquid Glass 材质
- SwiftUI `.menuBarExtraStyle(.window)` 会应用系统默认材质，手动覆盖会脱离系统视觉

**验证**：
- 运行 App，深浅模式截图，对比系统 WiFi 弹窗
- 检查文字可读性（不应因背景变化导致对比度不足）

### 5.2 修改点 2：接管方式分段控件改用 Picker

**文件**：`Silkway/Views/MenuBar/QuickControls.swift:14-25`

**现状**（自绘）：
```swift
HStack(spacing: 0) {
    takeoverButton("系统代理", active: !config.tunEnabled)
    takeoverButton("TUN", active: config.tunEnabled)
}
.padding(2)
.background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
```

**改为**（系统控件）：
```swift
Picker("接管方式", selection: Binding(
    get: { config.tunEnabled },
    set: { wantTUN in
        guard wantTUN != config.tunEnabled else { return }
        Task { await switchTakeover(toTUN: wantTUN) }
    }
)) {
    Text("系统代理").tag(false)
    Text("TUN").tag(true)
}
.pickerStyle(.segmented)
.labelsHidden()  // 标签已在行首显示
```

**依据**：
- Kit `Segmented Controls/Dark/Content Area/Duo/3 Rg`（ID: `42577747-9DF5-47AA-BD4B-48DEC8D76EAA`）
- HIG 推荐使用系统分段控件而非自绘
- `Picker(.segmented)` 自动获得焦点/键盘导航/Liquid Glass 样式

**保留行为**：
- 切换时仍调用 `switchTakeover(toTUN:)`（改配置 + 重启 sing-box）
- 切换期间禁用（`isSwitching` 状态）

**验证**：
- 运行 App，切换接管方式，验证：
  - 配置持久化（`appconfig.json` 中 `tunEnabled` 变化）
  - sing-box 重启（进程 ID 变化）
  - 系统代理/TUN 互斥（切换后另一方自动关闭）

### 5.3 修改点 3：出站模式分段控件改用 Picker

**文件**：`Silkway/Views/MenuBar/QuickControls.swift:47-68`

**现状**（自绘）：
```swift
HStack(spacing: 0) {
    ForEach(ProxyMode.allCases) { mode in
        Button { ... } label: {
            Text(mode.displayName)
                .background(
                    manager.mode == mode
                    ? Color.white.opacity(0.18)
                    : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
    }
}
```

**改为**（系统控件）：
```swift
Picker("出站模式", selection: Binding(
    get: { manager.mode },
    set: { newMode in
        Task { await manager.setMode(newMode) }
    }
)) {
    ForEach(ProxyMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
    }
}
.pickerStyle(.segmented)
.labelsHidden()
```

**依据**：
- Kit `Segmented Controls/Dark/Content Area/Trio/3 Rg`（需检索实际 ID）
- 同上（修改点 2）

**保留行为**：
- 切换时仍调用 `manager.setMode(newMode)`（热切换，不重启）
- 未运行时先记偏好，UI 立即反馈

**验证**：
- 运行 App，切换模式，验证：
  - 模式立即生效（`/configs` API 返回新模式）
  - UI 选中态正确（当前模式高亮）
  - 未运行时切换不影响下次启动

### 5.4 修改点 4：当前配置下拉菜单样式统一

**文件**：`Silkway/Views/MenuBar/QuickControls.swift:70-100`

**现状**：
```swift
Menu {
    // ...
} label: {
    HStack(spacing: 4) {
        Text(activeProfileName)
        Image(systemName: "chevron.up.chevron.down")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
}
.menuStyle(.borderlessButton)
```

**改为**：
```swift
Menu {
    // ...
} label: {
    HStack(spacing: 4) {
        Text(activeProfileName)
            .font(.system(size: 11))
        Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 8, weight: .bold))
    }
    .foregroundStyle(ColorToken.textSecondary)
}
.menuStyle(.borderlessButton)
.menuIndicator(.visible)  // 让系统绘制下拉箭头，不自绘 chevron
```

**依据**：
- Kit `Pop-up and Pull-down Buttons/Dark/...`（需检索实际 ID）
- HIG 推荐系统下拉按钮样式
- 移除自绘背景和圆角，让系统决定样式

**验证**：
- 运行 App，点击下拉菜单，验证：
  - 菜单展开正常
  - 选中项打勾显示
  - 切换配置仍触发重启

---

## 6. 验收标准

### 6.1 功能不变（回归测试）

- [ ] 55 项现有测试全部通过（`swift test`）
- [ ] 切换接管方式后 sing-box 重启（进程 ID 变化）
- [ ] 切换模式后 `/configs` API 返回新模式
- [ ] 切换配置后重启 sing-box
- [ ] 系统代理/TUN 互斥逻辑不破坏

### 6.2 视觉对齐（截图对比）

- [ ] 弹窗背景材质与系统 WiFi 弹窗一致（深浅模式）
- [ ] 分段控件样式与 Kit `Segmented Controls/Dark/Content Area/Duo & Trio/3 Rg` 一致
- [ ] 下拉菜单箭头由系统绘制（不自绘 chevron）

### 6.3 可访问性

- [ ] 分段控件支持键盘导航（Tab + 空格）
- [ ] 分段控件焦点环正确显示
- [ ] VoiceOver 朗读正确（可选验证）

### 6.4 状态覆盖

- [ ] 深色模式
- [ ] 浅色模式
- [ ] 窗口激活/非激活（菜单栏弹窗点外关闭后重开）
- [ ] 切换中禁用状态（`isSwitching`）
- [ ] 空状态（无订阅/无策略组）

---

## 7. 风险与限制

| 风险 | 缓解措施 |
|---|---|
| `Picker(.segmented)` 在菜单栏弹窗中的宽度可能不自适应 | 显式设置 `.frame(width: 200)` 或用 `.controlSize(.small)` |
| Liquid Glass 材质在某些 macOS 27 beta 版本不稳定 | 保留截图对比，如有问题回滚材质覆盖 |
| 自绘 Toggle 换成系统 Picker 后，切换动画可能变化 | 保留业务逻辑（`switchTakeover`），视觉差异接受系统行为 |
| 菜单栏弹窗的材质移除后，与浅色模式背景对比度可能不足 | 运行 App 截图验证，必要时加 `.background(.regularMaterial)` |

---

## 8. 未验证项

- [ ] Kit `Segmented Controls/Dark/Content Area/Trio/3 Rg` 的实际 layer ID（需检索）
- [ ] Kit `Pop-up and Pull-down Buttons/Dark/...` 的实际 layer ID（需检索）
- [ ] Liquid Glass 材质在浅色模式下的实际视觉效果（需运行 App 截图）
- [ ] `Picker(.segmented)` 在菜单栏弹窗中的实际宽度行为（需运行 App 验证）
- [ ] VoiceOver 朗读行为（可选，低优先级）

---

*文档版本: v1.0*
*创建日期: 2026-09-09*
*作者: AI Agent (Claude)*
*依据: Design/macos27-agent-kit/ (Apple macOS 27 UI Kit 27.0.1) + Apple HIG*
