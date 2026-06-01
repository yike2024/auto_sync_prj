#!/bin/bash
# =============================================================================
# 同步包装脚本
# 提供简化的命令行接口来调用主同步脚本
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync_gerrit_to_github.sh"
CONFIG_FILE="$SCRIPT_DIR/sync_config.conf"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 显示 logo
show_logo() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    echo "║     Gerrit → Github 源码同步工具                         ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# 显示帮助
show_help() {
    show_logo
    cat << EOF
用法: $(basename "$0") <命令> [选项]

命令:
  status          检查同步状态，显示目录差异
  preview         预览将要同步的变更 (干运行)
  sync            执行同步
  full-sync       执行全量同步 (强制更新所有文件)
  clean-logs      清理旧日志文件

选项:
  -v, --verbose   显示详细输出
  -h, --help      显示帮助信息

示例:
  # 检查状态
  $(basename "$0") status

  # 预览变更
  $(basename "$0") preview

  # 执行同步
  $(basename "$0") sync

  # 详细输出
  $(basename "$0") -v sync

配置文件:
  $CONFIG_FILE

EOF
}

# 检查环境
check_env() {
    if [[ ! -f "$SYNC_SCRIPT" ]]; then
        echo -e "${RED}错误: 找不到主同步脚本: $SYNC_SCRIPT${NC}"
        exit 1
    fi

    if [[ ! -x "$SYNC_SCRIPT" ]]; then
        chmod +x "$SYNC_SCRIPT"
    fi
}

# 显示状态
show_status() {
    show_logo
    echo -e "${BLUE}【同步状态检查】${NC}"
    echo ""

    if [[ ! -d "$GERRIT_DIR" ]]; then
        echo -e "${RED}✗ Gerrit 目录不存在: $GERRIT_DIR${NC}"
        return 1
    fi

    if [[ ! -d "$GITHUB_DIR" ]]; then
        echo -e "${RED}✗ Github 目录不存在: $GITHUB_DIR${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ 目录检查通过${NC}"
    echo "  Gerrit: $GERRIT_DIR"
    echo "  Github: $GITHUB_DIR"
    echo ""

    # 统计目录
    local gerrit_count=$(find "$GERRIT_DIR" -maxdepth 1 -type d ! -name ".*" | wc -l)
    local github_count=$(find "$GITHUB_DIR" -maxdepth 1 -type d ! -name ".*" | wc -l)

    echo "【目录统计】"
    echo "  Gerrit 目录数: $gerrit_count"
    echo "  Github 目录数: $github_count"
    echo ""

    # 共同目录
    local common=$(comm -12 <(ls "$GERRIT_DIR" | sort) <(ls "$GITHUB_DIR" | sort) | wc -l)
    local only_gerrit=$(comm -23 <(ls "$GERRIT_DIR" | sort) <(ls "$GITHUB_DIR" | sort) | wc -l)
    local only_github=$(comm -13 <(ls "$GERRIT_DIR" | sort) <(ls "$GITHUB_DIR" | sort) | wc -l)

    echo "【目录对比】"
    echo "  共同目录:     $common"
    echo "  仅 Gerrit:    $only_gerrit"
    echo "  仅 Github:    $only_github"
    echo ""

    if [[ $only_gerrit -gt 0 ]]; then
        echo -e "${YELLOW}【仅 Gerrit 存在的目录】${NC}"
        comm -23 <(ls "$GERRIT_DIR" | sort) <(ls "$GITHUB_DIR" | sort) | sed 's/^/  - /'
        echo ""
    fi

    if [[ $only_github -gt 0 ]]; then
        echo -e "${YELLOW}【仅 Github 存在的目录】${NC}"
        comm -13 <(ls "$GERRIT_DIR" | sort) <(ls "$GITHUB_DIR" | sort) | sed 's/^/  - /'
        echo ""
    fi

    # 检查磁盘空间
    echo "【磁盘空间】"
    df -h "$GITHUB_DIR" | tail -1 | awk '{print "  可用: " $4 " / 总计: " $2}'
    echo ""
}

# 预览同步
preview_sync() {
    show_logo
    echo -e "${BLUE}【同步预览】${NC}"
    echo ""

    if $VERBOSE; then
        "$SYNC_SCRIPT" --dry-run --verbose
    else
        "$SYNC_SCRIPT" --dry-run
    fi
}

# 执行同步
do_sync() {
    show_logo
    local mode=$1

    if [[ "$mode" == "full" ]]; then
        echo -e "${YELLOW}【全量同步模式】${NC}"
        echo "警告: 这将强制更新所有文件，无论是否已存在"
        echo ""

        read -p "确认执行全量同步? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "已取消"
            exit 0
        fi
    else
        echo -e "${GREEN}【增量同步模式】${NC}"
    fi
    echo ""

    # 构建参数
    local args=""
    [[ "$mode" == "full" ]] && args="$args --full-sync"
    $VERBOSE && args="$args --verbose"

    # 执行同步
    if "$SYNC_SCRIPT" $args; then
        echo ""
        echo -e "${GREEN}✓ 同步完成${NC}"
    else
        echo ""
        echo -e "${RED}✗ 同步失败${NC}"
        exit 1
    fi
}

# 清理日志
clean_logs() {
    show_logo
    echo -e "${BLUE}【清理日志】${NC}"
    echo ""

    if [[ ! -d "$LOG_DIR" ]]; then
        echo "日志目录不存在: $LOG_DIR"
        return 0
    fi

    local count=$(find "$LOG_DIR" -name "*.log" -type f | wc -l)
    echo "发现 $count 个日志文件"

    read -p "删除 $count 个日志文件? (yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        find "$LOG_DIR" -name "*.log" -type f -delete
        echo -e "${GREEN}✓ 已清理日志文件${NC}"
    else
        echo "已取消"
    fi
}

# 主入口
main() {
    # 解析命令
    local command=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            status|preview|sync|full-sync|clean-logs)
                command=$1
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
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

    # 检查环境
    check_env

    # 执行命令
    case $command in
        status)
            show_status
            ;;
        preview)
            preview_sync
            ;;
        sync)
            do_sync "incremental"
            ;;
        full-sync)
            do_sync "full"
            ;;
        clean-logs)
            clean_logs
            ;;
        "")
            show_help
            ;;
        *)
            echo "未知命令: $command"
            show_help
            exit 1
            ;;
    esac
}

# 运行
main "$@"
