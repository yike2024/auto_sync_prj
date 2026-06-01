#!/bin/bash
# =============================================================================
# 同步脚本: 从 Gerrit 仓库同步源码到 Github 仓库
# 说明:
#   - 只同步非 git 相关的源码文件
#   - 排除 .git, .repo 等版本控制目录
#   - 对于共同存在的目录: 只同步文件内容变化
#   - 对于 gerrit 特有的目录: 完整复制到 github
# =============================================================================

set -e

# 配置
GERRIT_DIR="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/gerrit_a2_release_code"
GITHUB_DIR="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/github_release_code_bm1688"
LOG_FILE="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/sync_$(date +%Y%m%d_%H%M%S).log"

# 排除模式 (rsync 格式)
EXCLUDE_PATTERNS=(
    ".git/"
    ".repo/"
    ".gitmodules"
    ".gitignore"
    "*.orig"
    "*.rej"
)

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }

# 检查目录是否存在
check_directories() {
    if [[ ! -d "$GERRIT_DIR" ]]; then
        error "Gerrit 目录不存在: $GERRIT_DIR"
        exit 1
    fi

    if [[ ! -d "$GITHUB_DIR" ]]; then
        error "Github 目录不存在: $GITHUB_DIR"
        exit 1
    fi

    info "目录检查通过"
    info "  Gerrit: $GERRIT_DIR"
    info "  Github: $GITHUB_DIR"
}

# 构建 rsync 排除参数
build_exclude_args() {
    local args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        args="$args --exclude='$pattern'"
    done
    echo "$args"
}

# 同步单个目录
sync_directory() {
    local src_dir=$1
    local dest_dir=$2
    local dir_name=$3

    info "同步目录: $dir_name"

    # 确保目标目录存在
    mkdir -p "$dest_dir"

    # 构建 rsync 命令
    local exclude_args=$(build_exclude_args)
    local rsync_cmd="rsync -av --delete $exclude_args '$src_dir/' '$dest_dir/'"

    info "执行: $rsync_cmd"

    if eval "$rsync_cmd" >> "$LOG_FILE" 2>&1; then
        info "目录同步成功: $dir_name"
        return 0
    else
        error "目录同步失败: $dir_name"
        return 1
    fi
}

# 获取目录列表 (排除隐藏目录)
get_directories() {
    local base_dir=$1
    find "$base_dir" -maxdepth 1 -type d ! -name ".*" | sed "s|$base_dir/||" | sed "s|$base_dir||" | grep -v "^$" | sort
}

# 主同步函数
main() {
    info "=========================================="
    info "开始同步 Gerrit -> Github"
    info "=========================================="

    # 检查目录
    check_directories

    # 获取目录列表
    info "扫描目录结构..."
    local gerrit_dirs=$(get_directories "$GERRIT_DIR")
    local github_dirs=$(get_directories "$GITHUB_DIR")

    info "Gerrit 目录数量: $(echo "$gerrit_dirs" | wc -l)"
    info "Github 目录数量: $(echo "$github_dirs" | wc -l)"

    # 统计
    local total=0
    local success=0
    local failed=0

    # 同步每个 gerrit 目录
    for dir in $gerrit_dirs; do
        total=$((total + 1))

        local src="$GERRIT_DIR/$dir"
        local dest="$GITHUB_DIR/$dir"

        if [[ -d "$src" ]]; then
            if sync_directory "$src" "$dest" "$dir"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done

    # 输出统计信息
    info "=========================================="
    info "同步完成"
    info "=========================================="
    info "总计: $total"
    info "成功: $success"
    info "失败: $failed"
    info "日志文件: $LOG_FILE"

    if [[ $failed -gt 0 ]]; then
        exit 1
    fi
}

# 处理命令行参数
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
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
        -h|--help)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --dry-run       模拟运行，不实际执行同步"
            echo "  --gerrit DIR    指定 Gerrit 目录"
            echo "  --github DIR    指定 Github 目录"
            echo "  -h, --help      显示帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

# 执行主函数
main "$@"
