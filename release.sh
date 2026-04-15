#!/bin/bash
set -e
cd "$(dirname "$0")"

# Config
APP_NAME="SwallowScreen"
VERSION=$(grep -A1 CFBundleShortVersionString SwallowScreen/Info.plist | tail -1 | sed 's/.*<string>\(.*\)<\/string>.*/\1/')
TAG="v${VERSION}"
GITHUB_REPO="Qithking/SwallowScreen"
GITEE_REPO=""
STAGE="/tmp/${APP_NAME,,}-release-${VERSION}"

echo "=== ${APP_NAME} Release ${TAG} ==="
echo ""

# Check if tag already exists on remote
if git ls-remote --tags origin | grep -q "refs/tags/${TAG}$"; then
    echo "Error: tag ${TAG} already exists. Bump version in SwallowScreen/Info.plist first."
    exit 1
fi

# Detect architecture
ARCH=$(uname -m)
echo "Current architecture: $ARCH"

# Clean old builds
echo "[1/6] Cleaning old builds..."
rm -rf .build
rm -rf "$STAGE"

# Build for Apple Silicon
echo "[2/6] Building Apple Silicon (arm64)..."
swift build -c release --arch arm64
ARM64_BIN=$(find .build -name "${APP_NAME}" -type f -executable 2>/dev/null | head -1)
if [ -z "$ARM64_BIN" ]; then
    echo "Error: Apple Silicon binary not found"
    exit 1
fi
echo "  Built: $ARM64_BIN"

# Build for Intel
echo "[3/6] Building Intel (x86_64)..."
swift build -c release --arch x86_64
X86_BIN=$(find .build -name "${APP_NAME}" -type f -executable 2>/dev/null | head -1)
if [ -z "$X86_BIN" ]; then
    echo "Error: Intel binary not found"
    exit 1
fi
echo "  Built: $X86_BIN"

# Package app bundles
echo "[4/6] Packaging apps..."

for label in Apple-Silicon Intel; do
    if [ "$label" = "Apple-Silicon" ]; then
        BIN="$ARM64_BIN"
    else
        BIN="$X86_BIN"
    fi
    APP_DIR="${STAGE}/${label}/${APP_NAME}.app/Contents"
    mkdir -p "$APP_DIR/MacOS" "$APP_DIR/Resources"
    cp "$BIN" "$APP_DIR/MacOS/"
    cp "SwallowScreen/Info.plist" "$APP_DIR/"
    cp -r "SwallowScreen/Assets.xcassets" "$APP_DIR/Resources/"
    cp "SwallowScreen/HelpView.html" "$APP_DIR/Resources/"
    echo "  Packaged ${label}"
done

# Create DMGs
echo "[5/6] Creating DMGs..."
for label in Apple-Silicon Intel; do
    DMG_NAME="${APP_NAME}-${TAG}-${label}.dmg"
    DMG_DIR="${STAGE}/dmg-${label}"
    mkdir -p "$DMG_DIR"
    cp -R "${STAGE}/${label}/${APP_NAME}.app" "$DMG_DIR/"
    ln -s /Applications "$DMG_DIR/Applications"
    hdiutil create -volname "${APP_NAME}" -srcfolder "$DMG_DIR" -ov -format UDZO \
        "${STAGE}/${DMG_NAME}" -quiet
    echo "  Created ${DMG_NAME}"
done

# Git commit, tag, push
echo "[6/6] Pushing tag and publishing release..."
git add -A
git diff --cached --quiet || git commit -m "${TAG}"
git tag "$TAG" 2>/dev/null || true
git push origin main --tags
if [ -n "$GITEE_REPO" ]; then
    git push gitee main --tags 2>/dev/null || echo "  Warning: failed to push to Gitee remote"
fi

# Upload to GitHub release
echo "Publishing release to GitHub..."
RELEASE_NOTES="## ${APP_NAME} ${TAG}

多屏幕窗口管理工具

### 系统要求
- macOS 13.0+

### 支持架构
- Apple Silicon (M1/M2/M3...)
- Intel Mac

### 功能
- 固定屏幕：指定应用只能在特定屏幕移动
- 多屏幕支持：为每个应用指定首选显示屏幕
- 全局快捷键：快速设置前台应用的屏幕
- 菜单栏应用：不占用 Dock 空间

### 下载
- **Apple Silicon (M1/M2/M3/M4)**: \`${APP_NAME}-${TAG}-Apple-Silicon.dmg\`
- **Intel**: \`${APP_NAME}-${TAG}-Intel.dmg\`

### 安装方式
打开 \`.dmg\` 文件，将 ${APP_NAME} 拖入 Applications 文件夹。
首次打开请前往 **系统设置 → 隐私与安全性** 点击"仍要打开"。"

gh release create "$TAG" \
    --repo "$GITHUB_REPO" \
    --title "${APP_NAME} ${TAG}" \
    --notes "$RELEASE_NOTES" \
    "${STAGE}/${APP_NAME}-${TAG}-Apple-Silicon.dmg" \
    "${STAGE}/${APP_NAME}-${TAG}-Intel.dmg"

echo "  GitHub release done"

# Upload to Gitee if configured
if [ -n "$GITEE_REPO" ] && [ -n "$GITEE_TOKEN" ]; then
    echo "Publishing release to Gitee..."
    GITEE_RELEASE_RESP=$(curl -s -X POST \
        "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases" \
        -H "Content-Type: application/json" \
        -H "Authorization: token ${GITEE_TOKEN}" \
        -d "{
            \"tag_name\": \"${TAG}\",
            \"name\": \"${APP_NAME} ${TAG}\",
            \"body\": \"${RELEASE_NOTES}\",
            \"target_commitish\": \"main\"
        }")

    GITEE_RELEASE_ID=$(echo "$GITEE_RELEASE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

    if [ -n "$GITEE_RELEASE_ID" ] && [ "$GITEE_RELEASE_ID" != "None" ]; then
        for label in Apple-Silicon Intel; do
            DMG_FILE="${STAGE}/${APP_NAME}-${TAG}-${label}.dmg"
            curl -s -X POST \
                "https://gitee.com/api/v5/repos/${GITEE_REPO}/releases/${GITEE_RELEASE_ID}/attach_files" \
                -H "Authorization: token ${GITEE_TOKEN}" \
                -F "file=@${DMG_FILE}" > /dev/null
            echo "  Uploaded ${APP_NAME}-${TAG}-${label}.dmg to Gitee"
        done
        echo "  Gitee release done"
    else
        echo "  Warning: Failed to create Gitee release"
    fi
fi

echo ""
echo "=== Done! Released ${TAG} ==="
echo "GitHub: https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
if [ -n "$GITEE_REPO" ]; then
    echo "Gitee:  https://gitee.com/${GITEE_REPO}/releases/tag/${TAG}"
fi

# Cleanup
rm -rf "$STAGE"
