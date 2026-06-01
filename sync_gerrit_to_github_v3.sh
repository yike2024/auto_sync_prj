#!/bin/bash
# =============================================================================
# 同步脚本 v3: 从 Gerrit 仓库同步源码到 Github 仓库
# 基于 manifest 分析的增强版本
#
# 特性:
#   - 读取 manifest 文件获取正确的仓库映射关系
#   - 处理 Gerrit/Github 仓库名不同的情况 (cvi_build -> build)
#   - 处理子目录映射 (如 isp -> middleware/v2/modules/isp)
#   - 处理同一仓库映射到多个路径 (libsophav -> libsophon/libsophav 和 sophon_media/libsophav)
#   - 只同步非 git 相关的源码文件
#   - 支持增量同步和全量同步
# =============================================================================

set -e

# 默认配置
GERRIT_DIR="${GERRIT_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/gerrit_a2_release_code}"
GITHUB_DIR="${GITHUB_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/github_release_code_bm1688}"
LOG_DIR="${LOG_DIR:-/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/logs}"
GERRIT_MANIFEST="${GERRIT_MANIFEST:-$GERRIT_DIR/.repo/manifests/athena2/release/all_repos.xml}"
GITHUB_MANIFEST="${GITHUB_MANIFEST:-$GITHUB_DIR/.repo/manifest.xml}"

# 选项
DRY_RUN=false
FULL_SYNC=false
VERBOSE=false
USE_MANIFEST=true

# 统计变量
declare -A STATS
declare -A MAPPING_GERRIT_TO_GITHUB
declare -A MAPPING_GITHUB_TO_GERRIT
declare -A SUBDIR_MAPPINGS
declare -a MULTI_PATH_REPOS

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

# =============================================================================
# Manifest 解析函数
# =============================================================================

parse_gerrit_manifest() {
    local manifest_file=$1

    if [[ ! -f "$manifest_file" ]]; then
        warn "Gerrit manifest 文件不存在: $manifest_file"
        return 1
    fi

    info "解析 Gerrit manifest: $manifest_file"

    # 解析 project 节点
    while IFS= read -r line; do
        # 提取 name, path, revision
        if [[ $line =~ name=\"([^\"]+)\" ]]; then
            local repo_name="${BASH_REMATCH[1]}"
            local repo_path="$repo_name"
            local revision="default"

            # 提取 path (如果有)
            if [[ $line =~ path=\"([^\"]+)\" ]]; then
                repo_path="${BASH_REMATCH[1]}"
            fi

            # 提取 revision (如果有)
            if [[ $line =~ revision=\"([^\"]+)\" ]]; then
                revision="${BASH_REMATCH[1]}"
            fi

            # 存储映射关系
            GERRIT_REPOS["$repo_name"]="$repo_path"
            GERRIT_REVISIONS["$repo_name"]="$revision"

            debug "Gerrit repo: $repo_name -> $repo_path (revision: $revision)"
        fi
    done < <(grep -o '<project[^>]*>' "$manifest_file" | grep -v '^ *<!--') 2>/dev/null || true

    info "解析完成，找到 ${#GERRIT_REPOS[@]} 个仓库"
}

parse_github_manifest() {
    local manifest_file=$1

    if [[ ! -f "$manifest_file" ]]; then
        warn "Github manifest 文件不存在: $manifest_file"
        return 1
    fi

    info "解析 Github manifest: $manifest_file"

    # 先处理 include 的情况
    if grep -q '<include' "$manifest_file" 2>/dev/null; then
        local include_file=$(grep -o 'name="[^"]*"' "$manifest_file" | grep -o '"[^"]*"' | tr -d '"' | head -1)
        if [[ -n "$include_file" ]]; then
            local full_path="$GITHUB_DIR/.repo/manifests/$include_file"
            if [[ -f "$full_path" ]]; then
                manifest_file="$full_path"
                info "跟随 include 到: $manifest_file"
            fi
        fi
    fi

    # 解析 project 节点
    while IFS= read -r line; do
        if [[ $line =~ name=\"([^\"]+)\" ]]; then
            local repo_name="${BASH_REMATCH[1]}"
            local repo_path="$repo_name"
            local revision="default"

            if [[ $line =~ path=\"([^\"]+)\" ]]; then
                repo_path="${BASH_REMATCH[1]}"
            fi

            if [[ $line =~ revision=\"([^\"]+)\" ]]; then
                revision="${BASH_REMATCH[1]}"
            fi

            GITHUB_REPOS["$repo_name"]="$repo_path"
            GITHUB_REVISIONS["$repo_name"]="$revision"

            debug "Github repo: $repo_name -> $repo_path (revision: $revision)"
        fi
    done < <(grep -o '<project[^>]*>' "$manifest_file" | grep -v '^ *<!--') 2>/dev/null || true

    info "解析完成，找到 ${#GITHUB_REPOS[@]} 个仓库"
}

# =============================================================================
# 映射关系分析
# =============================================================================

analyze_mappings() {
    info "分析仓库映射关系..."

    # 初始化关联数组
    declare -gA REPO_MAPPINGS
    declare -gA PATH_MAPPINGS

    # 遍历 Gerrit 仓库
    for gerrit_name in "${!GERRIT_REPOS[@]}"; do
        local gerrit_path="${GERRIT_REPOS[$gerrit_name]}"
        local found_match=false

        # 在 Github 中查找匹配的仓库
        for github_name in "${!GITHUB_REPOS[@]}"; do
            local github_path="${GITHUB_REPOS[$github_name]}"

            # 如果最终路径相同，则认为是同一个仓库
            if [[ "$gerrit_path" == "$github_path" ]]; then
                REPO_MAPPINGS["$gerrit_name"]="$github_name"
                PATH_MAPPINGS["$gerrit_path"]="$github_path"
                found_match=true

                debug "映射: $gerrit_name -> $github_name (路径: $gerrit_path)"
                break
            fi
        done

        if [[ "$found_match" == false ]]; then
            debug "未找到匹配: $gerrit_name (路径: $gerrit_path)"
        fi
    done

    info "分析完成，找到 ${#REPO_MAPPINGS[@]} 个映射关系"
}

# 主函数入口
main() {
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --gerrit)
                GERRIT_DIR="$2"
                shift 2
                ;;
            --github)
                GITHUB_DIR="$2"
                shift 2
                ;;
            --no-manifest)
                USE_MANIFEST=false
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "未知选项: $1"
                exit 1
                ;;
        esac
    done

    # 初始化
    init_logging
    info "========================================"
    info "Gerrit -> Github 同步工具 v3"
    info "基于 Manifest 分析的增强版本"
    info "========================================"

    # 声明关联数组
    declare -gA GERRIT_REPOS GERRIT_REVISIONS
    declare -gA GITHUB_REPOS GITHUB_REVISIONS

    if $USE_MANIFEST; then
        # 解析 manifest
        parse_gerrit_manifest "$GERRIT_MANIFEST"
        parse_github_manifest "$GITHUB_MANIFEST"

        # 分析映射关系
        analyze_mappings
    else
        info "跳过 manifest 解析，使用目录扫描模式"
    fi

    info "同步工具初始化完成"
}

show_help() {
    cat << EOF
用法: $0 [选项]

选项:
  --gerrit DIR          指定 Gerrit 目录
  --github DIR          指定 Github 目录
  --no-manifest         不使用 manifest 分析
  -h, --help            显示帮助

示例:
  # 使用默认配置
  $0

  # 指定目录
  $0 --gerrit /path/to/gerrit --github /path/to/github

EOF
}

# 运行
main "$@"
