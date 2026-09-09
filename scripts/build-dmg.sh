#!/bin/bash
# Silkway DMG 打包脚本
# 用法：./scripts/build-dmg.sh

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "=== Silkway DMG 打包 ==="

# 1. Release 构建
echo "→ 构建 Release 版本..."
xcodebuild -project Silkway.xcodeproj \
  -scheme Silkway \
  -configuration Release \
  -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED" | tail -1

# 2. 找到构建产物
RELEASE_APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Silkway-*/Build/Products/Release/Silkway.app 2>/dev/null | head -1)
if [ ! -d "$RELEASE_APP" ]; then
  echo "❌ 找不到 Release 构建产物"
  exit 1
fi
echo "✓ 构建产物: $RELEASE_APP"

# 3. 验证签名
echo "→ 验证签名..."
codesign --verify --deep --strict "$RELEASE_APP" || {
  echo "❌ 签名验证失败"
  exit 1
}
echo "✓ 签名有效"

# 4. 准备 DMG 内容
echo "→ 准备 DMG 内容..."
TMP_DIR="/tmp/silkway-dmg-$$"
mkdir -p "$TMP_DIR"
cp -R "$RELEASE_APP" "$TMP_DIR/"
ln -s /Applications "$TMP_DIR/Applications"

# 5. 写安装说明
cat > "$TMP_DIR/README.txt" << 'EOF'
Silkway 安装说明

1. 拖动 Silkway.app 到 Applications 文件夹

2. 首次运行：
   - 双击 /Applications/Silkway.app
   - 系统可能提示「无法验证开发者」，点「打开」
   - 或者：右键 Silkway.app → 打开

3. TUN 模式（可选，全局接管流量）：
   - 必须把 Silkway.app 放在 /Applications 路径（不是其他位置）
   - 系统设置 → 通用 → 登录项与扩展 → 批准 Silkway 后台运行

4. 系统代理模式（默认，无需额外授权）：
   - 菜单栏 Silkway 图标 → 点电源键连接
   - 自动接管 HTTP/HTTPS/SOCKS 代理

项目主页：https://github.com/Kevin-osss/Silkway
EOF

# 6. 获取版本号
VERSION=$(xcodebuild -project Silkway.xcodeproj -scheme Silkway -configuration Release -showBuildSettings 2>/dev/null | grep "MARKETING_VERSION" | head -1 | awk '{print $3}')
if [ -z "$VERSION" ]; then
  VERSION="1.0.0"
fi

# 7. 创建 DMG
echo "→ 创建 DMG..."
DMG_NAME="Silkway-${VERSION}.dmg"
rm -f "$DMG_NAME"
hdiutil create -volname "Silkway" \
  -srcfolder "$TMP_DIR" \
  -ov -format UDZO \
  "$DMG_NAME" 2>&1 | grep -E "created|WARNING" | head -1

# 8. 清理
rm -rf "$TMP_DIR"

echo ""
echo "✅ DMG 打包完成: $PROJECT_ROOT/$DMG_NAME"
ls -lh "$DMG_NAME" | awk '{print "   大小: " $5}'
echo ""
echo "安装方法："
echo "  1. 双击 $DMG_NAME"
echo "  2. 拖动 Silkway.app 到 Applications"
echo "  3. 双击 /Applications/Silkway.app 运行"
