#!/bin/bash
# =============================================================================
# Gerrit -> Github 仓库同步脚本 v2
# 支持配置文件控制同步行为
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/sync_repos.conf"

# ========== 默认配置 ==========
GERRIT_DIR="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/gerrit_a2_release_code"
GITHUB_DIR="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/github_release_code_bm1688"
LOG_DIR="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/logs"
DRY_RUN=false
VERBOSE=false

# 同步策略开关（会被配置文件覆盖）
SYNC_COMMON_REPOS=true
SYNC_SUBDIR_MAPPINGS=true
SYNC_GERRIT_ONLY_REPOS=false
DELETE_EXTRA_FILES=false

# ========== 仓库定义 ==========
# 共同仓库（路径相同）
COMMON_REPOS=(
    "cvi_rtsp" "fsbl" "host-tools" "isp-tool-daemon"
    "isp_tuning" "libsophon" "linux_5.10" "linux-common"
    "sophon_media" "tdl_sdk" "u-boot-2021.10"
)

# Gerrit 特有仓库
GERRIT_ONLY_REPOS=(
    "arm-trusted-firmware" "fip.bin" "frameworks"
    "fsbl.patch" "mediapipe" "opensbi"
    "pytest" "rel_bin" "sophgo-develop-docs"
    "testcases" "tools" "tpu-kernel"
)

# 子目录映射
SUBDIR_MAP=(
    "libsophon/libsophav:libsophon/libsophav"
    "sophon_media/libsophav:sophon_media/libsophav"
    "middleware/v2/modules/isp:middleware/v2/modules/isp"
    "middleware/v2/component/SensorSupportList:middleware/v2/component/SensorSupportList"
    "ubuntu/bootloader-arm64:ubuntu/bootloader-arm64"
    "frameworks/nvr_edge:frameworks/nvr_edge"
)

# 排除列表
EXCLUDE_COMMON_REPOS=()
EXCLUDE_SUBDIR_MAPPINGS=()
EXCLUDE_GERRIT_ONLY_REPOS=()

# ========== 日志函数 ==========
log() { echo "[$(date '+%H:%M:%S')] [$1] ${*:2}"; }
info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }

# ========== 加载配置 ==========
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        info "加载配置文件: $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        warn "配置文件不存在: $CONFIG_FILE，使用默认配置"
    fi
}

# ========== 检查是否在排除列表 ==========
is_excluded() {
    local item="$1"
    shift
    local list=("$@")
    for excluded in "${list[@]}"; do
        [[ "$item" == "$excluded" ]] && return 0
    done
    return 1
}

# ========== 同步目录 ==========
sync_dir() {
    local src="$1" dest="$2" name="$3"
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

# ========== 显示对比 ==========
show_compare() {
    info "========================================"
    info "仓库对比分析 (配置文件控制)"
    info "========================================"
    info "配置文件: $CONFIG_FILE"
    info ""
    info "同步策略:"
    info "  - 共同仓库: $SYNC_COMMON_REPOS"
    info "  - 子目录映射: $SYNC_SUBDIR_MAPPINGS"
    info "  - Gerrit特有仓库: $SYNC_GERRIT_ONLY_REPOS"
    info ""
    
    # 1. 共同仓库
    if $SYNC_COMMON_REPOS; then
        info "【共同仓库 - 将同步】"
        for repo in "${COMMON_REPOS[@]}"; do
            if is_excluded "$repo" "${EXCLUDE_COMMON_REPOS[@]}"; then
                echo "  ⊘ $repo (已排除)"
            elif [[ -d "$GERRIT_DIR/$repo" && -d "$GITHUB_DIR/$repo" ]]; then
                gcount=$(find "$GERRIT_DIR/$repo" -type f 2>/dev/null | wc -l)
                hcount=$(find "$GITHUB_DIR/$repo" -type f 2>/dev/null | wc -l)
                echo "  ✓ $repo (Gerrit: $gcount, Github: $hcount)"
            fi
        done
        echo ""
    fi
    
    # 2. 子目录映射
    if $SYNC_SUBDIR_MAPPINGS; then
        info "【子目录映射 - 将同步】"
        for mapping in "${SUBDIR_MAP[@]}"; do
            IFS=':' read -r src dest <<< "$mapping"
            if is_excluded "$src" "${EXCLUDE_SUBDIR_MAPPINGS[@]}"; then
                echo "  ⊘ $src -> $dest (已排除)"
            elif [[ -d "$GERRIT_DIR/$src" ]]; then
                count=$(find "$GERRIT_DIR/$src" -type f 2>/dev/null | wc -l)
                echo "  ✓ $src -> $dest ($count 文件)"
            fi
        done
        echo ""
    fi
    
    # 3. Gerrit 特有仓库
    if $SYNC_GERRIT_ONLY_REPOS; then
        info "【Gerrit 特有仓库 - 将复制】"
        for repo in "${GERRIT_ONLY_REPOS[@]}"; do
            if is_excluded "$repo" "${EXCLUDE_GERRIT_ONLY_REPOS[@]}"; then
                echo "  ⊘ $repo (已排除)"
            elif [[ -d "$GERRIT_DIR/$repo" ]]; then
                count=$(find "$GERRIT_DIR/$repo" -type f 2>/dev/null | wc -l)
                echo "  + $repo ($count 文件)"
            fi
        done
    else
        info "【Gerrit 特有仓库 - 已跳过】"
        info "设置 SYNC_GERRIT_ONLY_REPOS=true 可开启同步"
    fi
}

# ========== 执行同步 ==========
perform_sync() {
    info "========================================"
    info "开始同步"
    info "========================================"
    local total=0 success=0 failed=0
    
    # 阶段 1: 共同仓库
    if $SYNC_COMMON_REPOS; then
        info "【阶段 1/3】同步共同仓库"
        for repo in "${COMMON_REPOS[@]}"; do
            is_excluded "$repo" "${EXCLUDE_COMMON_REPOS[@]}" && continue
            if [[ -d "$GERRIT_DIR/$repo" && -d "$GITHUB_DIR/$repo" ]]; then
                total=$((total + 1))
                sync_dir "$GERRIT_DIR/$repo" "$GITHUB_DIR/$repo" "$repo" && success=$((success + 1)) || failed=$((failed + 1))
            fi
        done
    fi
    
    # 阶段 2: 子目录映射
    if $SYNC_SUBDIR_MAPPINGS; then
        info ""
        info "【阶段 2/3】同步子目录映射"
        for mapping in "${SUBDIR_MAP[@]}"; do
            IFS=':' read -r src dest <<< "$mapping"
            is_excluded "$src" "${EXCLUDE_SUBDIR_MAPPINGS[@]}" && continue
            total=$((total + 1))
            sync_dir "$GERRIT_DIR/$src" "$GITHUB_DIR/$dest" "$src" && success=$((success + 1)) || failed=$((failed + 1))
        done
    fi
    
    # 阶段 3: Gerrit 特有仓库
    if $SYNC_GERRIT_ONLY_REPOS; then
        info ""
        info "【阶段 3/3】复制 Gerrit 特有仓库"
        for repo in "${GERRIT_ONLY_REPOS[@]}"; do
            is_excluded "$repo" "${EXCLUDE_GERRIT_ONLY_REPOS[@]}" && continue
            if [[ -d "$GERRIT_DIR/$repo" ]]; then
                total=$((total + 1))
                sync_dir "$GERRIT_DIR/$repo" "$GITHUB_DIR/$repo" "$repo" && success=$((success + 1)) || failed=$((failed + 1))
            fi
        done
    fi
    
    info ""
    info "========================================"
    info "同步完成: 总数=$total 成功=$success 失败=$failed"
    info "========================================"
}

# ========== 主函数 ==========
main() {
    # 先加载配置
    load_config
    
    case "$1" in
        --compare)
            show_compare
            ;;
        --sync|--dry-run)
            [[ "$1" == "--dry-run" ]] && DRY_RUN=true
            perform_sync
            ;;
        *)
            echo "用法: $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --compare     显示仓库对比分析"
            echo "  --sync        执行同步"
            echo "  --dry-run     干运行模式"
            echo ""
            echo "配置文件: $CONFIG_FILE"
            echo "编辑配置文件可控制同步行为"
            ;;
    esac
}

main "$@"
