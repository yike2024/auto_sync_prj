#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/sync_gerrit_to_github.conf"
PARSE_MANIFEST="${SCRIPT_DIR}/lib/parse_manifest.py"

GERRIT_DIR=""
GITHUB_DIR=""
LOG_DIR=""
AUTO_CHECKOUT_GERRIT=true
DELETE_EXTRA_FILES=false
SYNC_ONLY_EXISTING=true
DRY_RUN=false
REPO_PREPARE_BEFORE_SYNC=true
REPO_PREPARE_GERRIT=true
REPO_PREPARE_GITHUB=true
REPO_CLEAN_WORKTREE=true
REPO_SYNC_J=4
REPO_BRANCHES_APPLIED=false
GIT_STAGE_AFTER_SYNC=false
GERRIT_DEFCONFIG_FSBL="edge_wevb_emmc"
GERRIT_DEFCONFIG_LINUX_510="edge_wevb_emmc"
GERRIT_DEFCONFIG_LINUX_COMMON="edge_emmc_debian"
TDE_2D_ENGINE_REL="osdrv/interdrv/v2/2d_engine"
SYNC_REPO_RULES=()
SYNC_RULES_FILE=""
RSYNC_EXCLUDES=()
RSYNC_BUILD_ARTIFACT_EXCLUDES=()

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] ${*:2}"; }
info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        warn "配置文件不存在: $CONFIG_FILE，使用默认路径"
        GERRIT_DIR="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/gerrit_a2_release_code"
        GITHUB_DIR="/media/cvitek/ke.yi/mycode/sophon/dailybuild/auto_sync_prj/github_release_code_bm1688"
    fi
    LOG_DIR="${SCRIPT_DIR}/logs"
}

write_sync_rules_file() {
    SYNC_RULES_FILE="${SCRIPT_DIR}/.sync_rules.tmp"
    : > "$SYNC_RULES_FILE"
    if [[ ${#SYNC_REPO_RULES[@]} -eq 0 ]]; then
        error "SYNC_REPO_RULES 为空，请在 $CONFIG_FILE 中配置要同步的仓库"
        return 1
    fi
    local rule
    for rule in "${SYNC_REPO_RULES[@]}"; do
        [[ "$rule" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${rule//[[:space:]]/}" ]] && continue
        echo "$rule" >> "$SYNC_RULES_FILE"
    done
    if [[ ! -s "$SYNC_RULES_FILE" ]]; then
        error "SYNC_REPO_RULES 无有效规则"
        return 1
    fi
    return 0
}

github_parent_repo_path() {
    local gh_path="$1"
    local parent="${gh_path%/*}"
    while [[ -n "$parent" ]]; do
        if grep -q "^sync|${parent}|" <<< "$(plan_data_lines)" 2>/dev/null; then
            echo "$parent"
            return 0
        fi
        parent="${parent%/*}"
    done
    echo "$gh_path"
}

plan_data_lines() {
    echo "$SYNC_PLAN_RAW" | grep -v '^GERRIT_MANIFEST=\|^GITHUB_MANIFEST='
}

require_repo_cmd() {
    if ! command -v repo >/dev/null 2>&1; then
        error "未找到 repo 命令，请先安装并加入 PATH"
        return 1
    fi
}

checkout_repo_branch() {
    local repo_path="$1"
    local branch="$2"
    local label="$3"

    [[ -z "$branch" || "$branch" == "-" ]] && return 0

    if [[ ! -d "$repo_path/.git" ]]; then
        warn "$label 不是 git 仓库，跳过分支切换"
        return 0
    fi

    pushd "$repo_path" >/dev/null
    git fetch origin "$branch" 2>/dev/null || true
    if git checkout "$branch" 2>/dev/null; then
        git pull origin "$branch" 2>/dev/null || true
        info "  $label: 已切换到 $branch"
        popd >/dev/null
        return 0
    fi
    popd >/dev/null
    error "  $label: 切换到 $branch 失败"
    return 1
}

repo_prepare_workspace() {
    local root_dir="$1"
    local label="$2"

    require_repo_cmd || return 1

    if [[ ! -d "${root_dir}/.repo" ]]; then
        error "${label} 不是 repo 工作区: ${root_dir}"
        return 1
    fi

    info "========================================"
    info "${label}: repo sync (清理并拉取 manifest 指定版本)"
    info "========================================"

    pushd "$root_dir" >/dev/null

    repo sync -j"${REPO_SYNC_J}" -d --force-sync --no-clone-bundle || {
        popd >/dev/null
        error "${label}: repo sync 失败"
        return 1
    }

    if $REPO_CLEAN_WORKTREE; then
        info "${label}: repo forall 重置工作区 (reset --hard + clean -fdx)"
        repo forall -vc 'git reset --hard HEAD && git clean -fdx' || {
            popd >/dev/null
            error "${label}: repo forall clean 失败"
            return 1
        }
    fi

    popd >/dev/null
    info "${label}: repo 工作区准备完成"
    return 0
}

apply_branches_from_plan() {
    local root_dir="$1"
    local side="$2"
    local path_field rev_field

    case "$side" in
        gerrit)
            path_field=3
            rev_field=5
            ;;
        github)
            path_field=2
            rev_field=7
            ;;
        *)
            error "未知 side: $side"
            return 1
            ;;
    esac

    info "按 manifest 切换 ${side} 各仓库分支（仅 SYNC_REPO_RULES 中的项）"
    local line path rev label failed=0 merge_flag checkout_path
    while IFS='|' read -r status gh_path gr_path _gr_name gr_rev _gh_name gh_rev _excludes merge_flag; do
        [[ "$status" == "sync" ]] || continue

        if [[ "$side" == "gerrit" ]]; then
            path="$gr_path"
            rev="$gr_rev"
            label="gerrit/${path}"
            checkout_path="$path"
        else
            rev="$gh_rev"
            if [[ "$merge_flag" == "1" ]]; then
                checkout_path="$(github_parent_repo_path "$gh_path")"
                label="github/${checkout_path} (含并入子目录 ${gh_path})"
            else
                checkout_path="$gh_path"
                label="github/${checkout_path}"
            fi
            path="$checkout_path"
        fi

        [[ -z "$path" || "$path" == "-" ]] && continue
        checkout_repo_branch "${root_dir}/${path}" "$rev" "$label" || failed=$((failed + 1))
    done <<< "$(plan_data_lines)"

    [[ $failed -eq 0 ]]
}

prepare_all_repos_workspace() {
    if $DRY_RUN; then
        info "[DRY-RUN] repo 准备: sync + reset/clean + manifest 分支 + pull"
        $REPO_PREPARE_GERRIT && info "[DRY-RUN] Gerrit: $GERRIT_DIR"
        $REPO_PREPARE_GITHUB && info "[DRY-RUN] Github: $GITHUB_DIR"
        return 0
    fi

    if $REPO_PREPARE_GERRIT; then
        repo_prepare_workspace "$GERRIT_DIR" "Gerrit" || return 1
        apply_branches_from_plan "$GERRIT_DIR" "gerrit" || return 1
    fi

    if $REPO_PREPARE_GITHUB; then
        repo_prepare_workspace "$GITHUB_DIR" "Github" || return 1
        apply_branches_from_plan "$GITHUB_DIR" "github" || return 1
    fi

    REPO_BRANCHES_APPLIED=true
    return 0
}

prepare_repos_before_sync() {
    if ! $REPO_PREPARE_BEFORE_SYNC; then
        info "已跳过 repo 准备 (REPO_PREPARE_BEFORE_SYNC=false)"
        return 0
    fi
    prepare_all_repos_workspace
}

perform_repo_prep_only() {
    local prep_gerrit=true
    local prep_github=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --gerrit-only) prep_github=false ;;
            --github-only) prep_gerrit=false ;;
        esac
        shift
    done

    if ! $prep_gerrit && ! $prep_github; then
        error "不能同时指定 --gerrit-only 与 --github-only"
        return 1
    fi

    load_sync_plan || return 1
    mkdir -p "$LOG_DIR"
    local log_file="${LOG_DIR}/repo_prep_$(date '+%Y%m%d_%H%M%S').log"
    exec > >(tee -a "$log_file") 2>&1

    info "========================================"
    info "repo 工作区准备（仅切分支/更新/清理，不同步文件）"
    info "GERRIT_DIR (源):   $GERRIT_DIR"
    info "GITHUB_DIR (目标): $GITHUB_DIR"
    info "LOG_DIR:           $LOG_DIR"
    info "日志文件: $log_file"
    info "========================================"

    REPO_PREPARE_GERRIT=$prep_gerrit
    REPO_PREPARE_GITHUB=$prep_github
    prepare_all_repos_workspace || return 1

    info "========================================"
    info "repo 工作区准备完成"
    info "========================================"
    return 0
}

github_stage_changes() {
    local dest="$1"
    local label="$2"

    if ! $GIT_STAGE_AFTER_SYNC; then
        return 0
    fi

    if $DRY_RUN; then
        info "[DRY-RUN] $label: git add（不 commit）"
        return 0
    fi

    if ! git -C "$dest" rev-parse --git-dir >/dev/null 2>&1; then
        warn "$label: 不在 git 仓库内，跳过 git add"
        return 0
    fi

    local git_root relpath
    git_root="$(git -C "$dest" rev-parse --show-toplevel)"
    if [[ "$dest" == "$git_root" ]]; then
        git -C "$git_root" add -A
    else
        relpath="${dest#"$git_root"/}"
        git -C "$git_root" add -A -- "$relpath"
    fi
    info "$label: 已 git add @ ${git_root}${relpath:+/$relpath}（未 commit）"
    return 0
}

append_rsync_excludes() {
    local -n _opts=$1
    local mode="$2"
    for pattern in "${RSYNC_EXCLUDES[@]}"; do
        _opts+=(--exclude="$pattern")
    done
    if [[ "$mode" == "source" ]]; then
        for pattern in "${RSYNC_BUILD_ARTIFACT_EXCLUDES[@]}"; do
            _opts+=(--exclude="$pattern")
        done
    fi
}

sync_one_path() {
    local gerrit_path="$1"
    local github_path="$2"
    local label="$3"
    local exclude_subpaths="$4"
    local gerrit_rev="$5"
    local mode="${6:-source}"

    local src="${GERRIT_DIR}/${gerrit_path}"
    local dest="${GITHUB_DIR}/${github_path}"

    if [[ ! -d "$src" ]]; then
        error "源目录不存在: $src ($label)"
        return 1
    fi

    if $AUTO_CHECKOUT_GERRIT && ! $REPO_BRANCHES_APPLIED && [[ -n "$gerrit_rev" && "$gerrit_rev" != "-" ]]; then
        checkout_repo_branch "$src" "$gerrit_rev" "$label" || return 1
    fi

    local rsync_opts=(-a)
    $DELETE_EXTRA_FILES && rsync_opts+=(--delete)
    [[ "$mode" == "source" && "$SYNC_ONLY_EXISTING" == true ]] && rsync_opts+=(--existing)
    append_rsync_excludes rsync_opts "$mode"

    if [[ "$github_path" == "osdrv" ]]; then
        rsync_opts+=(--exclude="interdrv/v2/2d_engine/")
    fi

    if [[ -n "$exclude_subpaths" && "$exclude_subpaths" != "-" ]]; then
        IFS=',' read -ra child_paths <<< "$exclude_subpaths"
        for child in "${child_paths[@]}"; do
            [[ -n "$child" ]] && rsync_opts+=(--exclude="${child}/")
        done
    fi

    if $DRY_RUN; then
        info "[DRY-RUN] $label ($mode): $src -> $dest"
        github_stage_changes "$dest" "$label"
        return 0
    fi

    mkdir -p "$dest"
    if rsync "${rsync_opts[@]}" "$src/" "$dest/"; then
        info "同步成功: $label ($mode)"
        github_stage_changes "$dest" "$label"
        return 0
    fi
    error "同步失败: $label"
    return 1
}

sync_release_path() {
    local rel_path="$1"
    local label="$2"
    local src="${GERRIT_DIR}/${rel_path}"
    local dest="${GITHUB_DIR}/${rel_path}"

    if [[ ! -d "$src" ]]; then
        error "源目录不存在: $src"
        return 1
    fi

    if $DRY_RUN; then
        info "[DRY-RUN] $label (release): $src -> $dest"
        github_stage_changes "$dest" "$label"
        return 0
    fi

    mkdir -p "$dest"
    local rsync_opts=(-a)
    $DELETE_EXTRA_FILES && rsync_opts+=(--delete)
    append_rsync_excludes rsync_opts "release"

    if rsync "${rsync_opts[@]}" "$src/" "$dest/"; then
        info "同步成功: $label (release)"
        github_stage_changes "$dest" "$label"
        return 0
    fi
    error "同步失败: $label"
    return 1
}

gerrit_source_envsetup() {
    cd "$GERRIT_DIR"
    # shellcheck source=/dev/null
    source build/envsetup_soc.sh
}

gerrit_apply_defconfig() {
    local board="$1"
    info "defconfig $board"
    defconfig "$board" || return 1
    gerrit_source_envsetup
}

run_a2_release_in_dir() {
    local rel_dir="$1"
    local full_dir="${GERRIT_DIR}/${rel_dir}"

    if [[ ! -f "${full_dir}/a2_release.sh" ]]; then
        error "找不到 ${rel_dir}/a2_release.sh"
        return 1
    fi

    pushd "$full_dir" >/dev/null
    chmod +x a2_release.sh
    ./a2_release.sh
    local ret=$?
    popd >/dev/null
    return $ret
}

restore_2d_engine_sources() {
    local osdrv_git="${GERRIT_DIR}/osdrv"
    if [[ ! -d "${osdrv_git}/.git" ]]; then
        error "osdrv 不是 git 仓库，无法恢复 2d_engine 源码"
        return 1
    fi
    info "恢复 2d_engine 源码 (git checkout)"
    git -C "$osdrv_git" checkout -- "interdrv/v2/2d_engine"
}

compile_and_prepare_fsbl() {
    info "========================================"
    info "FSBL: build_fsbl + a2_release.sh"
    info "========================================"

    gerrit_source_envsetup
    gerrit_apply_defconfig "$GERRIT_DEFCONFIG_FSBL" || return 1

    info "build_fsbl"
    build_fsbl || return 1

    info "fsbl/a2_release.sh"
    run_a2_release_in_dir "fsbl" || return 1

    info "FSBL 发布处理完成"
    return 0
}

compile_2d_engine_one_kernel() {
    local defconfig="$1"
    local kernel_label="$2"

    info "2d_engine [$kernel_label]: defconfig=$defconfig"
    gerrit_apply_defconfig "$defconfig" || return 1

    info "2d_engine [$kernel_label]: build_kernel"
    build_kernel || return 1

    info "2d_engine [$kernel_label]: build_osdrv 2d_engine"
    build_osdrv 2d_engine || return 1

    info "2d_engine [$kernel_label]: a2_release.sh (KERNEL_SRC=$KERNEL_SRC)"
    run_a2_release_in_dir "$TDE_2D_ENGINE_REL" || return 1

    return 0
}

compile_and_prepare_2d_engine() {
    info "========================================"
    info "2d_engine: 双内核编译发布"
    info "========================================"

    gerrit_source_envsetup

    info "阶段 1/2: linux-common ($GERRIT_DEFCONFIG_LINUX_COMMON)"
    compile_2d_engine_one_kernel "$GERRIT_DEFCONFIG_LINUX_COMMON" "linux-common" || return 1

    restore_2d_engine_sources || return 1

    info "阶段 2/2: linux_5.10 ($GERRIT_DEFCONFIG_LINUX_510)"
    compile_2d_engine_one_kernel "$GERRIT_DEFCONFIG_LINUX_510" "linux_5.10" || return 1

    info "2d_engine 发布处理完成"
    return 0
}

load_sync_plan() {
    if [[ ! -f "$PARSE_MANIFEST" ]]; then
        error "找不到 manifest 解析脚本: $PARSE_MANIFEST"
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        error "需要 python3 来解析 manifest"
        return 1
    fi
    write_sync_rules_file || return 1
    SYNC_PLAN_RAW="$(python3 "$PARSE_MANIFEST" "$GERRIT_DIR" "$GITHUB_DIR" "$SYNC_RULES_FILE")"
}

show_compare() {
    load_sync_plan
    local gerrit_mf="" github_mf=""
    while IFS= read -r line; do
        [[ "$line" == GERRIT_MANIFEST=* ]] && gerrit_mf="${line#GERRIT_MANIFEST=}"
        [[ "$line" == GITHUB_MANIFEST=* ]] && github_mf="${line#GITHUB_MANIFEST=}"
    done <<< "$SYNC_PLAN_RAW"

    info "Gerrit manifest: $gerrit_mf"
    info "Github manifest: $github_mf"
    info "仅同步 SYNC_REPO_RULES 中列出的仓库"
    info "普通仓库: 仅更新 Github 已有文件 (--existing)，不同步 Gerrit 多出的文件"
    info "同步前 repo: Gerrit=$REPO_PREPARE_GERRIT Github=$REPO_PREPARE_GITHUB clean=$REPO_CLEAN_WORKTREE"
    info "同步后 Github: 不自动 git add (GIT_STAGE_AFTER_SYNC=$GIT_STAGE_AFTER_SYNC)，请自行 git status / git add"
    info ""
    info "【普通仓库 - 源码同步】"
    while IFS='|' read -r status gh_path gr_path gr_name gr_rev gh_name gh_rev excludes merge_flag; do
        [[ "$status" == "sync" ]] || continue
        [[ "$gh_path" == "fsbl" ]] && continue
        local child_note=""
        [[ -n "$excludes" && "$excludes" != "-" ]] && child_note=" [排除子路径: ${excludes//,/, }]"
        local osdrv_note=""
        [[ "$gh_path" == "osdrv" ]] && osdrv_note=" [排除 ${TDE_2D_ENGINE_REL}]"
        local merge_note=""
        [[ "$merge_flag" == "1" ]] && merge_note=" [Github 无独立仓，并入父仓库]"
        echo "  * $gh_path <- gerrit/$gr_path ($gr_name, $gr_rev)$merge_note$child_note$osdrv_note"
    done <<< "$(plan_data_lines)"

    info ""
    info "【特殊编译后同步】"
    echo "  * fsbl: build_fsbl -> a2_release.sh"
    echo "  * ${TDE_2D_ENGINE_REL}:"
    echo "      1) linux-common: defconfig $GERRIT_DEFCONFIG_LINUX_COMMON -> build_kernel -> build_osdrv 2d_engine -> a2_release.sh"
    echo "      2) git checkout 恢复源码"
    echo "      3) linux_5.10: defconfig $GERRIT_DEFCONFIG_LINUX_510 -> build_kernel -> build_osdrv 2d_engine -> a2_release.sh"

    info ""
    info "【跳过】"
    while IFS='|' read -r status gh_path _gr_path _gr_name _gr_rev gh_name _gh_rev _excludes _merge_flag; do
        [[ "$status" == "no_gerrit" ]] || continue
        echo "  - $gh_path ($gh_name) 在 Gerrit 无对应路径"
    done <<< "$(plan_data_lines)"
}

perform_sync() {
    local skip_fsbl=false
    local skip_2d_engine=false
    local fsbl_only=false
    local tde_only=false
    local skip_compile=false
    local skip_repo_prep=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-fsbl) skip_fsbl=true ;;
            --skip-2d-engine) skip_2d_engine=true ;;
            --fsbl-only) fsbl_only=true ;;
            --2d-engine-only) tde_only=true ;;
            --skip-compile) skip_compile=true ;;
            --skip-repo-prep) skip_repo_prep=true ;;
        esac
        shift
    done

    load_sync_plan
    mkdir -p "$LOG_DIR"
    local log_file="${LOG_DIR}/sync_$(date '+%Y%m%d_%H%M%S').log"
    exec > >(tee -a "$log_file") 2>&1
    info "========================================"
    info "开始同步"
    info "GERRIT_DIR (源):   $GERRIT_DIR"
    info "GITHUB_DIR (目标): $GITHUB_DIR"
    info "LOG_DIR:           $LOG_DIR"
    info "日志文件: $log_file"
    info "========================================"

    REPO_BRANCHES_APPLIED=false
    if $skip_repo_prep; then
        info "已跳过 repo 准备 (--skip-repo-prep)"
    elif $REPO_PREPARE_BEFORE_SYNC; then
        local prep_github=$REPO_PREPARE_GITHUB
        if $fsbl_only || $tde_only; then
            prep_github=false
        fi
        local saved_github=$REPO_PREPARE_GITHUB
        REPO_PREPARE_GITHUB=$prep_github
        prepare_repos_before_sync || return 1
        REPO_PREPARE_GITHUB=$saved_github
    fi

    local total=0 success=0 failed=0

    if ! $fsbl_only && ! $tde_only; then
        info "========================================"
        info "普通仓库源码同步"
        info "========================================"

        while IFS='|' read -r status gh_path gr_path gr_name gr_rev gh_name gh_rev excludes; do
            [[ "$status" == "sync" ]] || continue
            is_manual_excluded "$gh_path" && continue
            [[ "$gh_path" == "fsbl" ]] && continue
            [[ "$excludes" == "-" ]] && excludes=""

            total=$((total + 1))
            if sync_one_path "$gr_path" "$gh_path" "$gh_path" "$excludes" "$gr_rev" "source"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
            fi
        done <<< "$(echo "$SYNC_PLAN_RAW" | grep -v '^GERRIT_MANIFEST=\|^GITHUB_MANIFEST=')"
    fi

    if ! $skip_fsbl && ! $tde_only; then
        info ""
        info "========================================"
        info "FSBL"
        info "========================================"
        total=$((total + 1))
        if $skip_compile; then
            sync_release_path "fsbl" "fsbl" && success=$((success + 1)) || failed=$((failed + 1))
        else
            if compile_and_prepare_fsbl && sync_release_path "fsbl" "fsbl"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    fi

    if ! $skip_2d_engine && ! $fsbl_only; then
        info ""
        info "========================================"
        info "2d_engine"
        info "========================================"
        total=$((total + 1))
        if $skip_compile; then
            sync_release_path "$TDE_2D_ENGINE_REL" "2d_engine" && success=$((success + 1)) || failed=$((failed + 1))
        else
            if compile_and_prepare_2d_engine && sync_release_path "$TDE_2D_ENGINE_REL" "2d_engine"; then
                success=$((success + 1))
            else
                failed=$((failed + 1))
            fi
        fi
    fi

    info ""
    info "========================================"
    info "同步完成: 总数=$total 成功=$success 失败=$failed"
    info "========================================"
    [[ $failed -eq 0 ]]
}

show_help() {
    cat <<EOF
================================================================================
  Gerrit -> Github 自动同步（SYNC_REPO_RULES + manifest 分支）
================================================================================

当前配置路径（来自 $CONFIG_FILE）:
  GERRIT_DIR (源):   ${GERRIT_DIR:-未设置}
  GITHUB_DIR (目标): ${GITHUB_DIR:-未设置}
  LOG_DIR:           ${LOG_DIR:-${SCRIPT_DIR}/logs}

用法: $0 <命令> [选项...]

不带参数、-h、--help 时显示本帮助。

--------------------------------------------------------------------------------
命令
--------------------------------------------------------------------------------
  --compare                显示同步计划（不修改任何文件）
  --repo-prep-only         仅准备 Gerrit/Github 工作区（切分支、更新、清理）
  --sync                   完整同步（repo 准备 + rsync + 编译项）
  --dry-run                预览全流程（不 rsync、不 repo 实操作）
  --fsbl-only              仅 FSBL（编译 + 同步）
  --fsbl-sync-only         仅 FSBL 同步（跳过编译）
  --2d-engine-only         仅 2d_engine（双内核编译 + 同步）
  --2d-engine-sync-only    仅 2d_engine 同步（跳过编译）
  -h, --help               显示本帮助

--------------------------------------------------------------------------------
选项（用于 --sync / --dry-run / --fsbl-* / --2d-engine-*）
--------------------------------------------------------------------------------
  --skip-fsbl              跳过 FSBL
  --skip-2d-engine         跳过 2d_engine
  --skip-compile           跳过所有编译，仅 rsync 已有发布产物
  --skip-repo-prep         跳过 repo sync / clean / 切分支

--------------------------------------------------------------------------------
选项（仅用于 --repo-prep-only）
--------------------------------------------------------------------------------
  --gerrit-only            只处理 GERRIT_DIR
  --github-only            只处理 GITHUB_DIR

--------------------------------------------------------------------------------
--repo-prep-only 说明（不 rsync、不编译）
--------------------------------------------------------------------------------
  对 SYNC_REPO_RULES 中列出的各仓库:
    1. repo sync -j\${REPO_SYNC_J} -d --force-sync
    2. repo forall: git reset --hard HEAD && git clean -fdx
    3. 按 manifest 对映射仓库 checkout 分支并 git pull
  日志: \${SCRIPT_DIR}/logs/repo_prep_YYYYMMDD_HHMMSS.log

  示例:
    $0 --repo-prep-only
    $0 --repo-prep-only --gerrit-only

--------------------------------------------------------------------------------
--sync 完整流程
--------------------------------------------------------------------------------
  阶段 1  repo 准备（Gerrit+Github，可用 --skip-repo-prep 或 --repo-prep-only 单独做）
  阶段 2  普通仓 Gerrit -> Github rsync（--existing，不增加 Github 没有的文件）
          osdrv 排除 interdrv/v2/2d_engine 子目录
  阶段 3  FSBL: defconfig -> build_fsbl -> fsbl/a2_release.sh -> rsync -> git add
  阶段 4  2d_engine:
          linux-common 编译 -> a2_release.sh
          git checkout 恢复 2d_engine 源码
          linux_5.10 编译 -> a2_release.sh -> rsync -> git add
  阶段 5  各 Github 仓 git add，不 commit（可用配置关闭）
  日志: \${SCRIPT_DIR}/logs/sync_YYYYMMDD_HHMMSS.log

  同步开始时会打印 GERRIT_DIR、GITHUB_DIR、LOG_DIR。

--------------------------------------------------------------------------------
常用示例
--------------------------------------------------------------------------------
  $0 --compare
  $0 --dry-run
  $0 --repo-prep-only
  $0 --sync
  $0 --sync --skip-repo-prep
  $0 --sync --skip-fsbl --skip-2d-engine
  $0 --fsbl-only
  $0 --fsbl-sync-only
  $0 --2d-engine-only
  $0 --2d-engine-sync-only

  同步后人工处理（推荐，便于区分新增与修改）:
    cd <GITHUB_DIR>/<仓库>
    git status
    git add <路径>    # 按需暂存
    git commit -m "..."

--------------------------------------------------------------------------------
配置文件: $CONFIG_FILE
--------------------------------------------------------------------------------
  GERRIT_DIR                     Gerrit 源根目录（绝对路径，必改）
  GITHUB_DIR                     Github 目标根目录（绝对路径，必改）

  REPO_PREPARE_BEFORE_SYNC        同步前是否 repo 准备（默认 true）
  REPO_PREPARE_GERRIT            是否准备 Gerrit 侧（默认 true）
  REPO_PREPARE_GITHUB            是否准备 Github 侧（默认 true）
  REPO_CLEAN_WORKTREE            是否 reset --hard && clean -fdx（默认 true）
  REPO_SYNC_J                    repo sync 并行数（默认 4）

  GIT_STAGE_AFTER_SYNC           同步后自动 git add（默认 false，建议手动 add）
  SYNC_ONLY_EXISTING             不向 Github 添加 Gerrit 独有文件（默认 true）
  DELETE_EXTRA_FILES             rsync --delete（默认 false，慎用）

  GERRIT_DEFCONFIG_FSBL          FSBL 板级配置（默认 edge_wevb_emmc）
  GERRIT_DEFCONFIG_LINUX_510     2d_engine linux_5.10（默认 edge_wevb_emmc）
  GERRIT_DEFCONFIG_LINUX_COMMON  2d_engine linux-common（默认 edge_emmc_debian）
  TDE_2D_ENGINE_REL              2d_engine 相对路径（仓库内路径）
  MANUAL_EXCLUDE_PATHS           手动排除项（如 sophliteos）

  日志目录固定为脚本同目录 logs/，无需在 conf 中配置 LOG_DIR。

--------------------------------------------------------------------------------
注意事项
--------------------------------------------------------------------------------
  - git clean -fdx 会删除未跟踪文件，运行前请确认无需要保留的本地改动
  - 本脚本不执行 git commit / git push
  - 旧版 sync_repos.sh / sync_fsbl.sh 与本脚本独立

  更详细说明见: \${SCRIPT_DIR}/readme.txt

EOF
}

main() {
    load_config

    case "${1:-}" in
        --compare)
            show_compare
            ;;
        --repo-prep-only)
            perform_repo_prep_only "${@:2}"
            ;;
        --sync)
            perform_sync "${@:2}"
            ;;
        --dry-run)
            DRY_RUN=true
            perform_sync "${@:2}"
            ;;
        --fsbl-only)
            perform_sync --fsbl-only "${@:2}"
            ;;
        --fsbl-sync-only)
            perform_sync --fsbl-only --skip-compile "${@:2}"
            ;;
        --2d-engine-only)
            perform_sync --2d-engine-only "${@:2}"
            ;;
        --2d-engine-sync-only)
            perform_sync --2d-engine-only --skip-compile "${@:2}"
            ;;
        -h|--help|"")
            show_help
            ;;
        *)
            error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
