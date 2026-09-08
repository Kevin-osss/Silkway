# Silkway

基于 [sing-box](https://sing-box.sagernet.org/) 内核的 macOS 菜单栏代理客户端。

![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/License-GPL--3.0-green)

## 功能

- **系统代理模式**：HTTP/HTTPS/SOCKS 接管（networksetup）
- **TUN 模式**：虚拟网卡全局接管（SMAppService daemon，root 权限）
- **绕过中国大陆**：geoip-cn + geosite-cn 本地规则集自动下载
- **订阅管理**：支持分享链接 / SIP008 / Clash YAML / 完整 sing-box 配置
- **菜单栏 UI**：连接开关、策略组展开、节点选择、批量测速、实时速率
- **设置面板**：通用 / 订阅 / 代理节点 / 路由规则 / DNS / 连接日志 / 关于

## 从零构建

```bash
# 1. 下载 sing-box 1.13.19（技术验证已锁版本，其他版本需重新验证）
mkdir -p spike
curl -sL -o /tmp/sing-box.tar.gz \
  https://github.com/SagerNet/sing-box/releases/download/v1.13.19/sing-box-1.13.19-darwin-arm64.tar.gz
tar -xzf /tmp/sing-box.tar.gz -C /tmp
cp /tmp/sing-box-1.13.19-darwin-arm64/sing-box spike/
cp spike/sing-box Silkway/Resources/

# 2. 生成 Xcode 工程（手写 pbxproj，非 Xcode 模板）
python3 scripts/generate-xcodeproj.py

# 3. 打开 Xcode，Signing 选你的 Personal Team（免费 Apple ID 即可）
open Silkway.xcodeproj
```

### TUN 模式额外要求

1. 把构建出的 `Silkway.app` 拷到 `/Applications`（SMAppService 的硬约束）
2. 系统设置 → 通用 → 登录项与扩展 → 批准 Silkway 后台运行

## 测试

```bash
swift test          # 55 项单元 + 集成测试（含 sing-box check 真实 schema 校验）
```

## 文档

| 文件 | 内容 |
|---|---|
| `Silkway_AI_Agent_Handbook.md` | 完整的开发手册（架构决策、已知陷阱、代码规范） |
| `Design/README.md` | 设计资产索引（原型、图标规格、配色 Token） |

## 许可证

GPL-3.0 —— sing-box 内核是 GPL-3.0，传染性条款要求衍生作品同许可。

`Silkway/Resources/sing-box` 和 `spike/sing-box` 是预编译二进制，**不入库**（.gitignore 排除），构建时按上面步骤自行下载。
