#!/bin/bash

set -e

# 配置
get_remote_info() {
    local remote_info
    remote_info=$(git remote -v 2>/dev/null | head -1)
    if [ -z "$remote_info" ]; then
        return 1
    fi
    # 提取仓库路径，支持 origin、SwallowScreen 等名称
    echo "$remote_info" | sed -E 's/.*github\.com[:/]([^.]+).*/\1/' | awk '{print $1}'
}

REPO_NAME=$(get_remote_info || echo "SwallowScreen")

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# 检查 Git 状态
check_git_status() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo_error "当前目录不是 Git 仓库"
        exit 1
    fi
}

# 获取最新版本号
get_latest_release() {
    curl -s "https://api.github.com/repos/Qithking/SwallowScreen/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || echo ""
}

# 获取当前 git 版本
get_current_version() {
    # 获取本地最新 tag
    git tag --sort=-version:refname 2>/dev/null | head -1 || echo "v0.0.0"
}

# 提交并推送代码
push_to_github() {
    echo ""
    echo "=== 提交代码到 GitHub ==="
    echo ""
    
    # 检查远程仓库
    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        exit 1
    fi
    echo_info "检测到远程仓库: $remote_name"
    
    # 检查分支
    current_branch=$(git branch --show-current)
    if [ "$current_branch" != "main" ]; then
        echo_warning "当前不在 main 分支 (当前: $current_branch)"
        read -p "是否切换到 main 分支? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            git checkout main
        else
            echo_info "继续在当前分支操作"
        fi
    fi
    
    # 显示更改
    echo ""
    echo_info "当前更改:"
    git status --short
    
    echo ""
    if git diff-index --quiet HEAD -- 2>/dev/null; then
        echo_info "没有需要提交的更改"
    else
        echo ""
        read -p "输入提交信息 (留空使用默认): " commit_msg
        if [ -z "$commit_msg" ]; then
            commit_msg="Update: $(date '+%Y-%m-%d %H:%M:%S')"
        fi
        
        echo ""
        echo_info "执行: git add . && git commit -m '$commit_msg'"
        git add .
        git commit -m "$commit_msg"
        
        echo ""
        echo_info "推送到 $remote_name/main..."
        git push "$remote_name" main
        
        echo_success "代码已成功推送到 GitHub!"
    fi
}

# 发布版本
create_release() {
    echo ""
    echo "=== 创建新版本 ==="
    echo ""
    
    # 检查 GitHub CLI
    if ! command -v gh &> /dev/null; then
        echo_error "需要安装 GitHub CLI"
        echo "安装命令: brew install gh"
        exit 1
    fi
    
    # 检查登录状态
    if ! gh auth status &> /dev/null; then
        echo_error "未登录 GitHub"
        echo "请运行: gh auth login"
        exit 1
    fi
    
    # 获取远程仓库名称
    remote_name=$(git remote 2>/dev/null | head -1)
    if [ -z "$remote_name" ]; then
        echo_error "未找到远程仓库"
        exit 1
    fi
    echo_info "检测到远程仓库: $remote_name"
    
    # 获取当前版本
    current_version=$(get_current_version)
    echo_info "当前版本: $current_version"
    
    echo ""
    read -p "输入新版本号 (格式: 1.0.0): " new_version
    
    # 验证版本格式并添加 v 前缀
    if [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        new_version="v$new_version"
    elif ! [[ "$new_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo_error "版本号格式错误，请使用 *.*.* 格式"
        exit 1
    fi
    
    echo_info "创建版本: $new_version"
    
    # 检查版本是否已存在
    if git tag | grep -q "^${new_version}$"; then
        echo_error "版本 $new_version 已存在"
        exit 1
    fi
    
    echo ""
    echo_info "创建 tag: $new_version"
    git tag "$new_version"
    
    echo ""
    echo_info "推送 tag 到 GitHub..."
    git push "$remote_name" "$new_version"
    
    echo_success "已创建版本 $new_version 并推送!"
    echo ""
    echo_info "GitHub Actions 将自动开始构建 DMG..."
    echo_info "查看构建进度: https://github.com/Qithking/SwallowScreen/actions"
}

# 下载最新版本
download_latest() {
    echo ""
    echo "=== 下载最新版本 ==="
    echo ""
    
    # 获取最新版本信息
    echo_info "正在获取最新版本信息..."
    
    # 检查 GitHub CLI
    if command -v gh &> /dev/null && gh auth status &> /dev/null; then
        latest_info=$(gh release view --repo Qithking/SwallowScreen --json tagName,url 2>/dev/null || echo "")
        latest_version=$(echo "$latest_info" | grep -o '"tagName"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    fi
    
    # 备用方案: 使用 API
    if [ -z "$latest_version" ]; then
        latest_version=$(curl -s "https://api.github.com/repos/Qithking/SwallowScreen/releases/latest" 2>/dev/null | \
            grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
    fi
    
    if [ -z "$latest_version" ]; then
        echo_error "无法获取最新版本，请检查仓库地址"
        exit 1
    fi
    
    echo_info "最新版本: $latest_version"
    
    # 下载 DMG
    dmg_name="SwallowScreen-${latest_version}-universal.dmg"
    download_url=""
    
    # 尝试从 GitHub Release 获取下载链接
    if command -v gh &> /dev/null && gh auth status &> /dev/null; then
        download_url=$(gh release view "$latest_version" --repo Qithking/SwallowScreen --json assets -q '.assets[] | select(.name | contains("dmg")) | .url' 2>/dev/null || echo "")
    fi
    
    # 构建直接下载链接
    if [ -z "$download_url" ]; then
        download_url="https://github.com/Qithking/SwallowScreen/releases/download/${latest_version}/${dmg_name}"
    fi
    
    echo ""
    echo_info "下载链接: $download_url"
    
    # 下载文件
    echo ""
    read -p "是否下载? (y/n): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        cd ~/Downloads
        echo_info "开始下载..."
        
        if command -v curl &> /dev/null; then
            curl -L -o "$dmg_name" "$download_url" 2>&1
        elif command -v wget &> /dev/null; then
            wget -O "$dmg_name" "$download_url"
        fi
        
        if [ -f "$dmg_name" ]; then
            echo_success "下载完成: ~/Downloads/$dmg_name"
            echo_info "文件大小: $(ls -lh "$dmg_name" | awk '{print $5}')"
        else
            echo_error "下载失败"
            exit 1
        fi
    fi
}

# 主菜单
show_menu() {
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║          SwallowScreen 发布工具 v1.0              ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║  1. 提交代码到 GitHub (main 分支)                 ║"
    echo "║  2. 发布新版本 (创建 tag 触发 GitHub Actions)     ║"
    echo "║  3. 下载最新版本 DMG                             ║"
    echo "║  0. 退出                                          ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""
}

# 主程序
main() {
    check_git_status
    
    while true; do
        show_menu
        read -p "请选择操作 (0-3): " choice
        
        case $choice in
            1)
                push_to_github
                ;;
            2)
                create_release
                ;;
            3)
                download_latest
                ;;
            0)
                echo_info "再见!"
                exit 0
                ;;
            *)
                echo_error "无效选择，请输入 0-3"
                ;;
        esac
        
        echo ""
        read -p "按 Enter 继续..." dummy
    done
}

main
