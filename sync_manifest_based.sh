#!/bin/bash
# =============================================================================
# 基于 Manifest 的同步脚本
# 处理 Gerrit <-> Github 的仓库映射关系
# =============================================================================

set -e

# 默认配置
GERRIT_DIR="${GERRIT_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/gerrit_a2_release_code}"
GITHUB_DIR="${GITHUB_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/github_release_code_bm1688}"
LOG_DIR="${LOG_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/logs}"

# 选项
DRY_RUN=false
VERBOSE=false

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# 日志函数
# =============================================================================

init_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/sync_manifest_$(date +%Y%m%d_%H%M%S).log"
    exec 1> >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)
}

log() {
    local level=$1
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] [%-5s] %s\n" "$timestamp" "$level" "$*"
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }
debug() { $VERBOSE && log "DEBUG" "$@"; }

# =============================================================================
# 仓库映射表 (基于 manifest 分析)
# =============================================================================

# Gerrit 仓库名 -> Github 仓库名 映射
declare -A REPO_NAME_MAPPINGS=(
    # [Gerrit]=Github
    ["cvi_build"]="build"
    ["cvitek/buildroot-2021.05"]="buildroot-2021.05"
    ["cvi_osdrv"]="osdrv"
    ["cvi_ramdisk"]="ramdisk"
    ["cvitek/oss"]="oss"
    ["cvi_middleware"]="middleware"
    ["cvitek/isp-tool-daemon"]="isp-tool-daemon"
    ["cvitek/tdl_sdk"]="tdl_sdk"
    ["cvitek/mediapipe"]="mediapipe"
    ["cvitek/SensorSupportList"]="SensorSupportList"
    ["nvr_edge"]="nvr_edge"
    ["pytest"]="pytest"
    ["pytest/testcases"]="pytest/testcases"
)

# Gerrit 路径 -> Github 路径 映射
# 用于处理子目录映射和特殊路径
declare -A PATH_MAPPINGS=(
    # [Gerrit路径]=Github路径
    ["libsophon/libsophav"]="libsophon/libsophav"
    ["sophon_media/libsophav"]="sophon_media/libsophav"
    ["middleware/v2/modules/isp"]="middleware/v2/modules/isp"
    ["middleware/v2/component/SensorSupportList"]="middleware/v2/component/SensorSupportList"
    ["ubuntu/bootloader-arm64"]="ubuntu/bootloader-arm64"
    ["frameworks/nvr_edge"]="frameworks/nvr_edge"
)

# 仅 Gerrit 有的仓库 (需要复制到 Github)
declare -a GERRIT_ONLY_REPOS=(
    "opensbi"
    "cvitek/SensorSupportList:middleware/v2/component/SensorSupportList"
    "nvr_edge:frameworks/nvr_edge"
    "cvitek/mediapipe:mediapipe"
    "sophgo-develop-docs"
    "pytest"
    "pytest/testcases:testcases"
)

# 仅 Github 有的仓库 (Github 特有)
declare -a GITHUB_ONLY_REPOS=(
    "sophliteos"
)

# 同一个仓库映射到多个路径的情况
declare -A MULTI_PATH_REPOS=(
    # [仓库名]="路径1 路径2"
    ["libsophav"]="libsophon/libsophav sophon_media/libsophav"
)

# =============================================================================
# 核心同步函数
# =============================================================================

get_github_repo_name() {
    local gerrit_name="$1"
    if [[ -n "${REPO_NAME_MAPPINGS[$gerrit_name]}" ]]; then
        echo "${REPO_NAME_MAPPINGS[$gerrit_name]}"
    else
        echo "$gerrit_name"
    fi
}

get_github_path() {
    local gerrit_path="$1"
    if [[ -n "${PATH_MAPPINGS[$gerrit_path]}" ]]; then
        echo "${PATH_MAPPINGS[$gerrit_path]}"
    else
        # 尝试替换仓库名
        local repo_name=$(basename "$gerrit_path")
        local parent_path=$(dirname "$gerrit_path")
        [[ "$parent_path" == "." ]] && parent_path=""

        local github_repo=$(get_github_repo_name "$repo_name")

        if [[ -n "$parent_path" ]]; then
            echo "${parent_path}/${github_repo}"
        else
            echo "$github_repo"
        fi
    fi
}

# 获取 Gerrit 中的所有仓库路径
get_gerrit_repo_paths() {
    local gerrit_dir="$1"
    find "$gerrit_dir" -maxdepth 1 -type d ! -name ".*" ! -name "lost+found" | sed "s|^$gerrit_dir/||" | grep -v "^$" | sort
}

# 获取 Github 中的所有仓库路径
get_github_repo_paths() {
    local github_dir="$1"
    find "$github_dir" -maxdepth 1 -type d ! -name ".*" ! -name "lost+found" | sed "s|^$github_dir/||" | grep -v "^$" | sort
}

# 同步单个目录
sync_directory() {
    local src_dir="$1"
    local dest_dir="$2"
    local repo_name="${3:-$(basename "$src_dir")}"

    info "同步仓库: $repo_name"
    debug "  源: $src_dir"
    debug "  目标: $dest_dir"

    # 检查源目录是否存在
    if [[ ! -d "$src_dir" ]]; then
        warn "源目录不存在: $src_dir"
        return 1
    fi

    # 干运行模式
    if $DRY_RUN; then
        info "  [DRY-RUN] 将同步: $repo_name"
        return 0
    fi

    # 确保目标目录存在
    mkdir -p "$dest_dir"

    # 执行 rsync
    local rsync_opts="-av --delete"
    rsync_opts="$rsync_opts --exclude=.git/ --exclude=.repo/ --exclude=.gitmodules --exclude=.gitignore"
    rsync_opts="$rsync_opts --exclude=*.orig --exclude=*.rej"

    if ! rsync $rsync_opts "$src_dir/" "$dest_dir/" 2>&1 | tee -a "$LOG_FILE"; then
        error "同步失败: $repo_name"
        return 1
    fi

    info "  同步完成: $repo_name"
    return 0
}

# 显示仓库对比表
show_repo_comparison() {
    info "========================================"
    info "仓库对比分析"
    info "========================================"
    echo ""

    # 获取目录列表
    local gerrit_repos=($(get_gerrit_repo_paths "$GERRIT_DIR"))
    local github_repos=($(get_github_repo_paths "$GITHUB_DIR"))

    info "Gerrit 仓库数量: ${#gerrit_repos[@]}"
    info "Github 仓库数量: ${#github_repos[@]}"
    echo ""

    # 创建关联数组
    declare -A gerrit_map github_map
    for repo in "${gerrit_repos[@]}"; do gerrit_map[$repo]=1; done
    for repo in "${github_repos[@]}"; do github_map[$repo]=1; done

    # 共同仓库
    info "【共同仓库】"
    local common_count=0
    for repo in "${gerrit_repos[@]}"; do
        if [[ -n "${github_map[$repo]}" ]]; then
            echo "  ✓ $repo"
            ((common_count++))
        fi
    done
    echo "  总计: $common_count 个"
    echo ""

    # 仅 Gerrit 有
    info "【仅 Gerrit 有的仓库】"
    local gerrit_only=0
    for repo in "${gerrit_repos[@]}"; do
        if [[ -z "${github_map[$repo]}" ]]; then
            echo "  + $repo"
            ((gerrit_only++))
        fi
    done
    echo "  总计: $gerrit_only 个"
    echo ""

    # 仅 Github 有
    info "【仅 Github 有的仓库】"
    local github_only=0
    for repo in "${github_repos[@]}"; do
        if [[ -z "${gerrit_map[$repo]}" ]]; then
            echo "  - $repo"
            ((github_only++))
        fi
    done
    echo "  总计: $github_only 个"
    echo ""
}

# 处理子目录同步
sync_subdirectory() {
    local gerrit_path="$1"
    local github_path="$2"

    local src="$GERRIT_DIR/$gerrit_path"
    local dest="$GITHUB_DIR/$github_path"

    if [[ ! -d "$src" ]]; then
        warn "子目录不存在: $src"
        return 1
    fi

    info "同步子目录: $gerrit_path -> $github_path"

    if $DRY_RUN; then
        info "  [DRY-RUN] 将同步子目录"
        return 0
    fi

    mkdir -p "$dest"

    local rsync_opts="-av --delete"
    rsync_opts="$rsync_opts --exclude=.git/ --exclude=.repo/ --exclude=.gitmodules --exclude=.gitignore"

    if rsync $rsync_opts "$src/" "$dest/" >> "$LOG_FILE" 2>&1; then
        info "  子目录同步完成"
        return 0
    else
        error "  子目录同步失败"
        return 1
    fi
}

# 处理多路径映射 (如 libsophav)
sync_multi_path_repo() {
    local repo_name="$1"
    local paths="${MULTI_PATH_REPOS[$repo_name]}"

    if [[ -z "$paths" ]]; then
        return 0
    fi

    info "处理多路径仓库: $repo_name"
    debug "  路径: $paths"

    for path in $paths; do
        sync_subdirectory "$path" "$path"
    done
}

# 主同步流程
perform_sync() {
    info "========================================"
    info "开始执行同步"
    info "========================================"
    echo ""

    # 统计
    local total=0 success=0 failed=0

    # 1. 同步共同仓库
    info "【阶段 1/3】同步共同仓库"
    echo ""

    for gerrit_repo in "${!REPO_NAME_MAPPINGS[@]}"; do
        local github_repo="${REPO_NAME_MAPPINGS[$gerrit_repo]}"

        # 检查是否是直接路径
        if [[ -d "$GERRIT_DIR/$gerrit_repo" ]]; then
            ((total++))
            if sync_directory "$GERRIT_DIR/$gerrit_repo" "$GITHUB_DIR/$github_repo" "$gerrit_repo"; then
                ((success++))
            else
                ((failed++))
            fi
        fi
    done

    # 2. 同步子目录映射
    info ""
    info "【阶段 2/3】同步子目录映射"
    echo ""

    for gerrit_path in "${!PATH_MAPPINGS[@]}"; do
        local github_path="${PATH_MAPPINGS[$gerrit_path]}"

        if [[ -d "$GERRIT_DIR/$gerrit_path" ]]; then
            ((total++))
            if sync_subdirectory "$gerrit_path" "$github_path"; then
                ((success++))
            else
                ((failed++))
            fi
        fi
    done

    # 3. 复制 Gerrit 特有仓库
    info ""
    info "【阶段 3/3】复制 Gerrit 特有仓库"
    echo ""

    for repo_mapping in "${GERRIT_ONLY_REPOS[@]}"; do
        local gerrit_name github_path

        if [[ "$repo_mapping" =~ : ]]; then
            gerrit_name="${repo_mapping%%:*}"
            github_path="${repo_mapping#*:}"
        else
            gerrit_name="$repo_mapping"
            github_path="$repo_mapping"
        fi

        if [[ -d "$GERRIT_DIR/$gerrit_name" ]]; then
            ((total++))
            if sync_directory "$GERRIT_DIR/$gerrit_name" "$GITHUB_DIR/$github_path" "$gerrit_name"; then
                ((success++))
            else
                ((failed++))
            fi
        fi
    done

    # 输出统计
    echo ""
    info "========================================"
    info "同步完成"
    info "========================================"
    info "总仓库数: $total"
    info "成功:     $success"
    info "失败:     $failed"
    info "日志文件: $LOG_FILE"
    info "========================================"
}

# 主函数
main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --gerrit)
                GERRIT_DIR="$2"
                shift 2
                ;;
            --github)
                GITHUB_DIR="$2"
                shift 2
                ;;
            --compare)
                init_logging
                show_repo_comparison
                exit 0
                ;;
            --sync)
                init_logging
                show_repo_comparison
                perform_sync
                exit 0
                ;;
            -h|--help)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --dry-run        干运行模式"
                echo "  --verbose        显示详细输出"
                echo "  --gerrit DIR     指定 Gerrit 目录"
                echo "  --github DIR     指定 Github 目录"
                echo "  --compare        显示仓库对比分析"
                echo "  --sync           执行同步"
                echo "  -h, --help       显示帮助"
                echo ""
                echo "示例:"
                echo "  # 查看对比分析"
                echo "  $0 --compare"
                echo ""
                echo "  # 干运行模式"
                echo "  $0 --dry-run --sync"
                echo ""
                echo "  # 执行同步"
                echo "  $0 --sync"
                exit 0
                ;;
            *)
                echo "未知选项: $1"
                exit 1
                ;;
        esac
    done

    # 默认行为：显示帮助
    echo "用法: $0 [选项]"
    echo ""
    echo "常用命令:"
    echo "  $0 --compare     显示仓库对比分析"
    echo "  $0 --sync        执行同步"
    echo "  $0 --dry-run --sync    干运行模式"
    echo ""
    echo "使用 --help 查看完整帮助"
}

# 运行
main "$@"
