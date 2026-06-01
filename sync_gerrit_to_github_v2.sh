#!/bin/bash
# =============================================================================
# 同步脚本 v2: 从 Gerrit 仓库同步源码到 Github 仓库
# 说明:
#   - 只同步非 git 相关的源码文件
#   - 排除 .git, .repo 等版本控制目录
#   - 支持增量同步和全量同步
#   - 提供详细的同步报告
# =============================================================================

set -e

# 默认配置
GERRIT_DIR="${GERRIT_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/gerrit_a2_release_code}"
GITHUB_DIR="${GITHUB_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/github_release_code_bm1688}"
LOG_DIR="${LOG_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/logs}"

# 选项
DRY_RUN=false
FULL_SYNC=false
VERBOSE=false

# 统计变量
STATS_total=0
STATS_success=0
STATS_failed=0
STATS_skipped=0
STATS_new=0

# 排除模式
EXCLUDE_PATTERNS=(
    ".git/"
    ".repo/"
    ".gitmodules"
    ".gitignore"
    "*.orig"
    "*.rej"
    ".cursor/"
)

# 日志函数
init_logging() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/sync_$(date +%Y%m%d_%H%M%S).log"
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

# 检查依赖
check_dependencies() {
    local missing=()

    for cmd in rsync find diff comm; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少必要的依赖: ${missing[*]}"
        exit 1
    fi
}

# 检查目录
check_directories() {
    if [[ ! -d "$GERRIT_DIR" ]]; then
        error "Gerrit 目录不存在: $GERRIT_DIR"
        exit 1
    fi

    if [[ ! -d "$GITHUB_DIR" ]]; then
        warn "Github 目录不存在，创建: $GITHUB_DIR"
        mkdir -p "$GITHUB_DIR"
    fi

    info "目录检查通过"
    info "  Gerrit: $GERRIT_DIR"
    info "  Github: $GITHUB_DIR"
}

# 构建 rsync 排除参数
build_rsync_excludes() {
    local args=""
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        args="$args --exclude='$pattern'"
    done
    echo "$args"
}

# 比较两个目录是否需要同步
needs_sync() {
    local src=$1
    local dest=$2

    # 如果目标不存在，需要同步
    if [[ ! -d "$dest" ]]; then
        return 0
    fi

    # 如果使用全量同步模式
    if $FULL_SYNC; then
        return 0
    fi

    # 使用 rsync 的 dry-run 检查是否有差异
    local exclude_args=$(build_rsync_excludes)
    local changes=$(eval "rsync -av --dry-run $exclude_args '$src/' '$dest/'" 2>/dev/null | grep -c -v '^sent\|^total\|^$' || true)

    if [[ $changes -gt 0 ]]; then
        return 0
    fi

    return 1
}

# 同步单个目录
sync_directory() {
    local src_dir=$1
    local dest_dir=$2
    local dir_name=$3

    STATS_total=$((STATS_total + 1))

    info "[$STATS_total] 处理目录: $dir_name"

    # 检查是否需要同步
    if ! needs_sync "$src_dir" "$dest_dir"; then
        debug "  无需同步 (内容相同): $dir_name"
        STATS_skipped=$((STATS_skipped + 1))
        return 0
    fi

    # 干运行模式
    if $DRY_RUN; then
        info "  [DRY-RUN] 将会同步: $dir_name"
        if [[ ! -d "$dest_dir" ]]; then
            STATS_new=$((STATS_new + 1))
        fi
        return 0
    fi

    # 确保目标目录存在
    mkdir -p "$dest_dir"

    # 构建并执行 rsync 命令
    local exclude_args=$(build_rsync_excludes)
    local rsync_cmd="rsync -av --delete $exclude_args '$src_dir/' '$dest_dir/'"

    debug "  执行: $rsync_cmd"

    if eval "$rsync_cmd" >> "$LOG_FILE" 2>&1; then
        if [[ ! -d "$dest_dir" ]] || [[ $(ls -A "$dest_dir" 2>/dev/null | wc -l) -eq 0 ]]; then
            STATS_new=$((STATS_new + 1))
        fi
        info "  同步成功: $dir_name"
        STATS_success=$((STATS_success + 1))
        return 0
    else
        error "  同步失败: $dir_name"
        STATS_failed=$((STATS_failed + 1))
        return 1
    fi
}

# 打印统计信息
print_stats() {
    echo ""
    echo "========================================"
    echo "同步统计报告"
    echo "========================================"
    echo "总处理目录数: $STATS_total"
    echo "同步成功:     $STATS_success"
    echo "同步失败:     $STATS_failed"
    echo "跳过(无变化): $STATS_skipped"
    echo "新增目录:     $STATS_new"
    echo "========================================"
    echo "日志文件: $LOG_FILE"
    echo "========================================"
}

# 主函数
main() {
    # 初始化日志
    init_logging

    info "========================================"
    info "Gerrit -> Github 同步工具"
    info "========================================"
    info "开始时间: $(date)"

    # 检查依赖
    check_dependencies

    # 检查目录
    check_directories

    # 打印配置
    info "配置信息:"
    info "  干运行模式: $DRY_RUN"
    info "  全量同步: $FULL_SYNC"
    info "  详细输出: $VERBOSE"

    # 获取 gerrit 目录列表
    local gerrit_dirs=$(find "$GERRIT_DIR" -maxdepth 1 -type d ! -name ".*" | sed "s|$GERRIT_DIR/||" | sed "s|$GERRIT_DIR||" | grep -v "^$")

    info "发现 $(echo "$gerrit_dirs" | wc -l) 个目录需要处理"

    # 处理每个目录
    for dir in $gerrit_dirs; do
        local src="$GERRIT_DIR/$dir"
        local dest="$GITHUB_DIR/$dir"

        sync_directory "$src" "$dest" "$dir"
    done

    # 打印统计
    print_stats

    info "结束时间: $(date)"

    # 返回退出码
    if [[ $STATS_failed -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# 显示帮助
show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  --dry-run          模拟运行，不实际执行同步
  --full-sync        强制全量同步，不检查文件变化
  --verbose          显示详细调试信息
  --gerrit DIR       指定 Gerrit 目录 (默认: $GERRIT_DIR)
  --github DIR       指定 Github 目录 (默认: $GITHUB_DIR)
  --log-dir DIR      指定日志目录 (默认: $LOG_DIR)
  -h, --help         显示帮助信息

示例:
  # 干运行模式 (测试配置)
  $0 --dry-run

  # 全量同步
  $0 --full-sync

  # 自定义目录
  $0 --gerrit /path/to/gerrit --github /path/to/github

EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --full-sync)
            FULL_SYNC=true
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
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 执行主函数
main "$@"
