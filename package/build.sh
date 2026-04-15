#!/bin/bash
#===============================================================================
# SwallowScreen Build Script for GitHub Action
# 完全在 GitHub Actions 上构建 universal 版 DMG 文件
# 仅需在本地执行 git tag 触发 workflow
#===============================================================================
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

#===============================================================================
# 配置
#===============================================================================
# GitHub Action 工作目录
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
cd "$GITHUB_WORKSPACE"

APP_NAME="SwallowScreen"
BUILD_DIR="/tmp/build"
STAGE_DIR="/tmp/stage"
OUTPUT_DIR="${GITHUB_WORKSPACE}/dist"

# GitHub 环境变量
GITHUB_REPO="${GITHUB_REPOSITORY:-Qithking/SwallowScreen}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

#===============================================================================
# 输出日志函数（支持 GitHub Actions）
#===============================================================================
log() {
    echo "$1"
    # GitHub Actions 日志格式化
    if [ -n "$GITHUB_OUTPUT" ]; then
        echo "$1" >> "$GITHUB_OUTPUT"
    fi
}

#===============================================================================
# 获取版本号
#===============================================================================
get_version() {
    # 从 Git tag 获取版本（触发 workflow 的 tag）
    local tag="${GITHUB_REF_NAME:-}"

    if [ -n "$tag" ]; then
        # 去掉 v 前缀
        echo "$tag" | sed 's/^v//'
        return
    fi

    # 备用：从 Package.swift 获取
    local pkg_version
    pkg_version=$(grep -E '^\s*version:' Package.swift 2>/dev/null | sed 's/.*version:\s*"\([^"]*\)".*/\1/')
    if [ -n "$pkg_version" ]; then
        echo "$pkg_version"
        return
    fi

    # 备用：使用 Git describe
    local describe
    describe=$(git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')
    if [ -n "$describe" ]; then
        echo "$describe"
        return
    fi

    log_error "无法获取版本号"
}

#===============================================================================
# 检查环境
#===============================================================================
check_environment() {
    log_info "检查构建环境..."

    # 检查 Swift
    if ! command -v swift &> /dev/null; then
        log_error "Swift 未安装"
    fi
    swift --version

    # 检查 hdiutil
    if ! command -v hdiutil &> /dev/null; then
        log_error "hdiutil 未找到"
    fi

    # 检查 lipo
    if ! command -v lipo &> /dev/null; then
        log_error "lipo 未找到"
    fi

    # 检查 GitHub Token
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN 环境变量未设置"
    fi

    log_ok "环境检查完成"
}

#===============================================================================
# 获取当前分支/提交信息
#===============================================================================
get_commit_info() {
    echo "Build Information:"
    echo "  Commit: $(git rev-parse --short HEAD)"
    echo "  Branch: $(git branch --show-current)"
    echo "  Tag: ${GITHUB_REF_NAME:-none}"
    echo "  Runner: $(sw_vers -productVersion)"
}

#===============================================================================
# 清理
#===============================================================================
cleanup() {
    log_info "清理旧构建..."
    rm -rf "${BUILD_DIR}" "${STAGE_DIR}" "${OUTPUT_DIR}"
    mkdir -p "${BUILD_DIR}/arm64"
    mkdir -p "${BUILD_DIR}/x86_64"
    mkdir -p "${STAGE_DIR}/dmg"
    mkdir -p "${OUTPUT_DIR}"
    log_ok "清理完成"
}

#===============================================================================
# 构建指定架构
#===============================================================================
build_architecture() {
    local arch="$1"
    local output_dir="$2"

    log_info "构建 ${arch}..."

    # 清理之前的构建
    rm -rf .build

    # Swift 构建
    log_info "执行 swift build -c release --arch ${arch}..."
    if ! swift build -c release --arch "$arch" 2>&1; then
        log_error "${arch} 构建失败"
    fi

    # 显示构建目录结构
    log_info "构建产物目录:"
    ls -la .build/

    # 查找二进制文件（排除符号链接和 .dylib）
    local binary
    binary=$(find .build -name "${APP_NAME}" -type f ! -name "*.dylib" -executable 2>/dev/null | head -1)

    # 如果没找到，尝试在 release 目录下查找
    if [ -z "$binary" ]; then
        binary=$(find .build/release -name "${APP_NAME}" -type f -executable 2>/dev/null | head -1)
    fi

    # 如果还没找到，尝试解析符号链接
    if [ -z "$binary" ]; then
        local release_link=".build/release"
        if [ -L "$release_link" ]; then
            local real_path
            real_path=$(readlink -f "$release_link")
            log_info "release 是符号链接: $real_path"
            binary=$(find "$real_path" -name "${APP_NAME}" -type f -executable 2>/dev/null | head -1)
        fi
    fi

    log_info "找到二进制: ${binary}"

    if [ -z "$binary" ] || [ ! -f "$binary" ]; then
        log_error "${arch} 二进制文件未找到"
    fi

    cp "$binary" "${output_dir}/${APP_NAME}"
    log_ok "${arch} 构建完成: ${output_dir}/${APP_NAME}"
}

#===============================================================================
# 创建通用二进制（合并 arm64 + x86_64）
#===============================================================================
create_universal_binary() {
    log_info "创建通用二进制..."

    local arm64_bin="${BUILD_DIR}/arm64/${APP_NAME}"
    local x86_bin="${BUILD_DIR}/x86_64/${APP_NAME}"
    local universal_bin="${STAGE_DIR}/dmg/${APP_NAME}"

    if [ ! -f "$arm64_bin" ]; then
        log_error "arm64 二进制文件未找到: ${arm64_bin}"
    fi

    if [ ! -f "$x86_bin" ]; then
        log_error "x86_64 二进制文件未找到: ${x86_bin}"
    fi

    lipo -create "$arm64_bin" "$x86_bin" -output "$universal_bin"

    if [ ! -f "$universal_bin" ]; then
        log_error "通用二进制创建失败"
    fi

    log_ok "通用二进制创建成功: $(lipo -info "$universal_bin")"
}

#===============================================================================
# 创建 App Bundle
#===============================================================================
create_app_bundle() {
    log_info "创建 App Bundle..."

    local app_dir="${STAGE_DIR}/dmg/${APP_NAME}.app/Contents"
    mkdir -p "$app_dir/MacOS"
    mkdir -p "$app_dir/Resources"

    # 复制二进制
    cp "${STAGE_DIR}/dmg/${APP_NAME}" "$app_dir/MacOS/"

    # Info.plist
    if [ -f "SwallowScreen/Info.plist" ]; then
        cp "SwallowScreen/Info.plist" "$app_dir/"
    else
        cat > "$app_dir/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacOS/SwallowScreen</string>
    <key>CFBundleIdentifier</key>
    <string>com.qithking.SwallowScreen</string>
    <key>CFBundleName</key>
    <string>SwallowScreen</string>
    <key>CFBundleDisplayName</key>
    <string>SwallowScreen</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF
    fi

    # 资源文件
    if [ -d "SwallowScreen/Assets.xcassets" ]; then
        cp -r "SwallowScreen/Assets.xcassets" "$app_dir/Resources/"
        log_ok "复制 Assets.xcassets"
    fi

    if [ -f "SwallowScreen/HelpView.html" ]; then
        cp "SwallowScreen/HelpView.html" "$app_dir/Resources/"
        log_ok "复制 HelpView.html"
    fi

    chmod +x "$app_dir/MacOS/SwallowScreen"

    log_ok "App Bundle 创建完成"
}

#===============================================================================
# 创建 DMG
#===============================================================================
create_dmg() {
    local version="$1"
    local output_path="$2"

    log_info "创建 DMG..."

    # 临时目录
    local temp_dir="${STAGE_DIR}/temp"
    mkdir -p "$temp_dir"

    # 复制 app 并创建 Applications 替身
    cp -R "${STAGE_DIR}/dmg/${APP_NAME}.app" "$temp_dir/"
    ln -s /Applications "$temp_dir/Applications"

    # 创建 DMG
    hdiutil create \
        -volname "${APP_NAME}" \
        -srcfolder "$temp_dir" \
        -ov \
        -format UDZO \
        -compression-level 9 \
        "$output_path" \
        -quiet

    # 清理临时目录
    rm -rf "$temp_dir"

    if [ ! -f "$output_path" ]; then
        log_error "DMG 创建失败"
    fi

    log_ok "DMG 创建完成: $(basename "$output_path")"
    ls -lh "$output_path"
}

#===============================================================================
# 创建 GitHub Release
#===============================================================================
create_github_release() {
    local version="$1"
    local dmg_path="$2"
    local tag="v${version}"

    log_info "创建 GitHub Release..."

    local release_notes="## ${APP_NAME} ${version}

多屏幕窗口管理工具

### 系统要求
- macOS 13.0+

### 支持架构
- Apple Silicon (M1/M2/M3/M4)
- Intel Mac

### 功能
- 固定屏幕：指定应用只能在特定屏幕移动
- 多屏幕支持：为每个应用指定首选显示屏幕
- 全局快捷键：快速设置前台应用的屏幕
- 菜单栏应用：不占用 Dock 空间

### 安装方式
1. 下载 DMG 文件
2. 打开 \`.dmg\` 文件
3. 将 ${APP_NAME} 拖入 Applications 文件夹
4. 首次打开请前往 **系统设置 → 隐私与安全性** 点击\"仍要打开\`
"

    # 检查 release 是否存在
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}")

    if [ "$http_code" = "200" ]; then
        log_info "Release ${tag} 已存在，获取 release ID..."
        local release_id
        release_id=$(curl -s \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${tag}" \
            | grep '"id":' | head -1 | grep -o '[0-9]*')

        local upload_url="https://uploads.github.com/repos/${GITHUB_REPO}/releases/${release_id}/attachments"

    else
        log_info "创建新 Release ${tag}..."

        local create_response
        create_response=$(curl -s -X POST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            -H "Content-Type: application/json" \
            "https://api.github.com/repos/${GITHUB_REPO}/releases" \
            -d "{
                \"tag_name\": \"${tag}\",
                \"name\": \"${APP_NAME} ${version}\",
                \"body\": $(echo "$release_notes" | jq -Rs .),
                \"draft\": false,
                \"prerelease\": false
            }")

        local release_id
        release_id=$(echo "$create_response" | grep '"id":' | head -1 | grep -o '[0-9]*')

        local upload_url
        upload_url=$(echo "$create_response" | grep -o '"upload_url": "[^"]*"' | cut -d'"' -f4 | cut -d'{' -f1)

        if [ -z "$upload_url" ]; then
            log_error "创建 Release 失败: $create_response"
        fi
    fi

    # 上传 DMG
    local filename
    filename=$(basename "$dmg_path")

    log_info "上传 ${filename}..."

    local upload_response
    upload_response=$(curl -s -X POST \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        "${upload_url}?name=${filename}" \
        --data-binary "@${dmg_path}")

    local download_url
    download_url=$(echo "$upload_response" | grep -o '"browser_download_url": "[^"]*"' | cut -d'"' -f4)

    if [ -n "$download_url" ]; then
        log_ok "上传成功: $download_url"
    else
        log_warn "上传响应: $upload_response"
    fi

    # 输出结果
    echo "release_url=${download_url}" >> "$GITHUB_OUTPUT"
    echo "version=${version}" >> "$GITHUB_OUTPUT"
    echo "dmg_path=${dmg_path}" >> "$GITHUB_OUTPUT"
}

#===============================================================================
# 主流程
#===============================================================================
main() {
    echo "=========================================="
    echo "  ${APP_NAME} GitHub Actions Build"
    echo "=========================================="
    echo ""

    # 显示环境信息
    get_commit_info
    echo ""

    # 检查环境
    check_environment

    # 获取版本
    VERSION=$(get_version)
    TAG="v${VERSION}"
    echo ""
    log_info "版本: ${VERSION}"
    log_info "Tag: ${TAG}"
    echo ""

    # 清理
    cleanup

    # 构建
    echo ""
    echo "=========================================="
    echo "  Building"
    echo "=========================================="
    echo ""

    build_architecture "arm64" "${BUILD_DIR}/arm64"
    build_architecture "x86_64" "${BUILD_DIR}/x86_64"

    # 创建通用二进制
    create_universal_binary

    # 创建 App Bundle
    create_app_bundle

    # 创建 DMG
    echo ""
    echo "=========================================="
    echo "  Creating DMG"
    echo "=========================================="
    echo ""

    DMG_PATH="${OUTPUT_DIR}/${APP_NAME}-${VERSION}-universal.dmg"
    create_dmg "$VERSION" "$DMG_PATH"

    # 上传到 GitHub Release
    echo ""
    echo "=========================================="
    echo "  Uploading to GitHub Release"
    echo "=========================================="
    echo ""

    create_github_release "$VERSION" "$DMG_PATH"

    # 完成
    echo ""
    echo "=========================================="
    echo -e "${GREEN}  构建完成!${NC}"
    echo "=========================================="
    echo ""
    echo "DMG: ${DMG_PATH}"
    echo "Version: ${VERSION}"
    echo ""
}

main "$@"
