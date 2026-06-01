#!/bin/bash
# =============================================================================
# Gerrit -> Github 仓库同步脚本 (简化版)
# 基于 manifest 分析的仓库映射关系
# =============================================================================

# 默认配置
GERRIT_DIR="${GERRIT_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/gerrit_a2_release_code}"
GITHUB_DIR="${GITHUB_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/github_release_code_bm1688}"
LOG_DIR="${LOG_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/logs}"

# 选项
DRY_RUN=false

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志
log() {
    local level=$1
    shift
    echo "[$(date '+%H:%M:%S')] [$level] $*"
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }

# 仓库映射表 - 基于 manifest 分析的仓库名映射
# 格式: [Gerrit仓库名]=Github仓库名
declare -A REPO_NAME_MAP=(
    # 仓库名不同的映射
    ["cvi_build"]="build"
    ["cvitek/buildroot-2021.05"]="buildroot"
    ["cvi_osdrv"]="osdrv"
    ["cvi_ramdisk"]="ramdisk"
    ["cvitek/oss"]="oss"
    ["cvi_middleware"]="middleware"
    ["cvitek/isp-tool-daemon"]="isp-tool-daemon"
    ["cvitek/tdl_sdk"]="tdl_sdk"
)

# 直接存在的共同仓库（无需映射）
declare -a COMMON_REPOS=(
    "cvi_rtsp"
    "fsbl"
    "host-tools"
    "isp-tool-daemon"
    "isp_tuning"
    "libsophon"
    "linux_5.10"
    "linux-common"
    "sophon_media"
    "tdl_sdk"
    "u-boot-2021.10"
)

# 仅 Gerrit 有的仓库（需要复制）
declare -a GERRIT_ONLY_REPOS=(
    "arm-trusted-firmware"
    "fip.bin"
    "frameworks"
    "fsbl.patch"
    "mediapipe"
    "opensbi"
    "pytest"
    "rel_bin"
    "sophgo-develop-docs"
    "testcases"
    "tools"
    "tpu-kernel"
)

# 子目录映射 (Gerrit路径 -> Github路径)
declare -A SUBDIR_MAP=(
    ["libsophon/libsophav"]="libsophon/libsophav"
    ["sophon_media/libsophav"]="sophon_media/libsophav"
    ["middleware/v2/modules/isp"]="middleware/v2/modules/isp"
    ["middleware/v2/component/SensorSupportList"]="middleware/v2/component/SensorSupportList"
    ["ubuntu/bootloader-arm64"]="ubuntu/bootloader-arm64"
    ["frameworks/nvr_edge"]="frameworks/nvr_edge"
)

# 同步目录
sync_dir() {
    local src="$1"
    local dest="$2"
    local name="$3"

    [[ ! -d "$src" ]] && { warn "源目录不存在: $src"; return 1; }

    if $DRY_RUN; then
        info "[DRY-RUN] 将同步: $name"
        return 0
    fi

    mkdir -p "$dest"

    rsync -av --delete \
        --exclude=".git/" --exclude=".repo/" \
        --exclude=".gitmodules" --exclude=".gitignore" \
        "$src/" "$dest/" > /dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        info "同步成功: $name"
        return 0
    else
        error "同步失败: $name"
        return 1
    fi
}

# 显示仓库对比
show_compare() {
    info "========================================"
    info "仓库对比分析"
    info "========================================"

    local gerrit_count=$(find "$GERRIT_DIR" -maxdepth 1 -type d ! -name ".*" | wc -l)
    local github_count=$(find "$GITHUB_DIR" -maxdepth 1 -type d ! -name ".*" | wc -l)

    info "Gerrit 仓库数: $gerrit_count"
    info "Github 仓库数: $github_count"
    echo ""

    # 共同仓库（无需映射）
    info "【共同仓库（无需映射）】"
    for repo in "${COMMON_REPOS[@]}"; do
        if [[ -d "$GERRIT_DIR/$repo" ]] && [[ -d "$GITHUB_DIR/$repo" ]]; then
            echo "  ✓ $repo"
        fi
    done
    echo ""

    # 仓库名不同的映射
    info "【仓库名不同的映射】"
    for gerrit_name in "${!REPO_NAME_MAP[@]}"; do
        local github_name="${REPO_NAME_MAP[$gerrit_name]}"
        if [[ -d "$GERRIT_DIR/$gerrit_name" ]] && [[ -d "$GITHUB_DIR/$github_name" ]]; then
            echo "  ✓ $gerrit_name -> $github_name"
        fi
    done
    echo ""

    # 子目录映射
    info "【子目录映射】"
    for src in "${!SUBDIR_MAP[@]}"; do
        local dest="${SUBDIR_MAP[$src]}"
        if [[ -d "$GERRIT_DIR/$src" ]]; then
            echo "  ✓ $src -> $dest"
        fi
    done
    echo ""

    # 仅 Gerrit 有
    info "【仅 Gerrit 有的仓库】"
    for repo in "${GERRIT_ONLY_REPOS[@]}"; do
        if [[ -d "$GERRIT_DIR/$repo" ]]; then
            echo "  + $repo"
        fi
    done
}

# 执行同步
perform_sync() {
    info "========================================"
    info "开始同步"
    info "========================================"

    local total=0 success=0 failed=0

    # 1. 共同仓库（无需映射）
    info "【阶段 1/4】同步共同仓库（无需映射）"
    for repo in "${COMMON_REPOS[@]}"; do
        if [[ -d "$GERRIT_DIR/$repo" ]] && [[ -d "$GITHUB_DIR/$repo" ]]; then
            total=$((total + 1))
            if sync_dir "$GERRIT_DIR/$repo" "$GITHUB_DIR/$repo" "$repo"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done

    # 2. 仓库名不同的映射
    info ""
    info "【阶段 2/4】同步仓库名不同的映射"
    for gerrit_name in "${!REPO_NAME_MAP[@]}"; do
        local github_name="${REPO_NAME_MAP[$gerrit_name]}"
        total=$((total + 1))
        if sync_dir "$GERRIT_DIR/$gerrit_name" "$GITHUB_DIR/$github_name" "$gerrit_name->$github_name"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done

    # 3. 同步子目录
    info ""
    info "【阶段 3/4】同步子目录映射"
    for src_path in "${!SUBDIR_MAP[@]}"; do
        local dest_path="${SUBDIR_MAP[$src_path]}"
        total=$((total + 1))
        if sync_dir "$GERRIT_DIR/$src_path" "$GITHUB_DIR/$dest_path" "$src_path"; then
            success=$((success + 1))
        else
            failed=$((failed + 1))
        fi
    done

    # 4. 复制 Gerrit 特有仓库
    info ""
    info "【阶段 4/4】复制 Gerrit 特有仓库"
    for repo in "${GERRIT_ONLY_REPOS[@]}"; do
        if [[ -d "$GERRIT_DIR/$repo" ]]; then
            total=$((total + 1))
            if sync_dir "$GERRIT_DIR/$repo" "$GITHUB_DIR/$repo" "$repo"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    done

    info ""
    info "========================================"
    info "同步完成统计:"
    info "  总数: $total"
    info "  成功: $success"
    info "  失败: $failed"
    info "========================================"
}

# 主函数
main() {
    case "$1" in
        --compare)
            show_compare
            ;;
        --sync)
            [[ "$2" == "--dry-run" ]] && DRY_RUN=true
            perform_sync
            ;;
        --dry-run)
            DRY_RUN=true
            perform_sync
            ;;
        *)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --compare    显示仓库对比分析"
            echo "  --sync       执行同步"
            echo "  --dry-run    干运行模式"
            echo ""
            echo "示例:"
            echo "  $0 --compare"
            echo "  $0 --dry-run"
            echo "  $0 --sync"
            ;;
    esac
}

main "$@"
