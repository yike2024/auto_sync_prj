================================================================================
  Gerrit -> Github 自动同步工具 (sync_gerrit_to_github.sh)
================================================================================

目录
----
  auto_sync_bash/
    sync_gerrit_to_github.sh    主脚本
    sync_gerrit_to_github.conf  配置文件
    lib/parse_manifest.py       manifest 解析
    readme.txt                  本说明

代码根目录（可在 conf 中修改）:
  gerrit_a2_release_code        Gerrit repo 工作区（源）
  github_release_code_bm1688    Github repo 工作区（目标）

前置条件
--------
  - 已安装 repo、python3、rsync、git
  - 两侧均已 repo init / repo sync 过，且 .repo 目录存在
  - Gerrit 侧可 source build/envsetup_soc.sh 并编译（FSBL、2d_engine 需要）

快速开始
--------
  cd auto_sync_prj/auto_sync_bash
  chmod +x sync_gerrit_to_github.sh

  # 查看将同步哪些仓库
  ./sync_gerrit_to_github.sh --compare

  # 预览（不 rsync、不 git add）
  ./sync_gerrit_to_github.sh --dry-run

  # 完整同步
  ./sync_gerrit_to_github.sh --sync

命令一览
--------
  --compare              显示同步计划，不修改任何文件
  --repo-prep-only       仅准备 Gerrit/Github 工作区（切分支、更新、清理）
  --sync                 执行完整同步流程
  --dry-run              预览全流程（不写文件）
  --fsbl-only            仅处理 FSBL（编译 + 同步 + git add）
  --fsbl-sync-only       仅 FSBL 同步（跳过编译）
  --2d-engine-only       仅 2d_engine（双内核编译 + 同步 + git add）
  --2d-engine-sync-only  仅 2d_engine 同步（跳过编译）
  -h, --help             显示帮助

选项（配合 --sync 等）
----------------------
  --skip-fsbl            跳过 FSBL
  --skip-2d-engine         跳过 2d_engine
  --skip-compile           跳过所有编译，仅 rsync 已有发布产物
  --skip-repo-prep         跳过 repo sync / clean / 切分支

仅准备工作区（--repo-prep-only）
--------------------------------
  不 rsync、不编译，只对 GERRIT_DIR / GITHUB_DIR 下所有子仓库:

    ./sync_gerrit_to_github.sh --repo-prep-only

  执行内容:
    1. repo sync -j4 -d --force-sync（manifest 指定版本）
    2. repo forall: git reset --hard && git clean -fdx（删除 git 未跟踪文件）
    3. 对 manifest 映射仓库 checkout 对应分支并 git pull 到最新

  可选:
    --gerrit-only          只处理 Gerrit 侧
    --github-only          只处理 Github 侧

  日志: auto_sync_bash/logs/repo_prep_YYYYMMDD_HHMMSS.log

完整同步流程（--sync）
----------------------
  阶段 1 - repo 准备（Gerrit + Github，可用 --skip-repo-prep 跳过）
    cd <工作区>
    repo sync -j4 -d --force-sync --no-clone-bundle
    repo forall -vc 'git reset --hard HEAD && git clean -fdx'
    按 manifest 将各子仓库切换到对应 revision

  阶段 2 - 普通仓库源码同步
    从 Gerrit rsync 到 Github（--existing：只更新 Github 已有文件，
    不把 Gerrit 多出来的图片等文件拷过去）
    osdrv 同步时排除 interdrv/v2/2d_engine 子目录

  阶段 3 - FSBL 特殊处理
    defconfig edge_wevb_emmc（可配置）
    build_fsbl
    cd fsbl && ./a2_release.sh
    rsync 到 github_release_code_bm1688/fsbl/
    git add（不 commit）

  阶段 4 - 2d_engine 特殊处理（osdrv/interdrv/v2/2d_engine）
    1) linux-common: defconfig edge_emmc_debian -> build_kernel
       -> build_osdrv 2d_engine -> a2_release.sh
    2) git checkout 恢复 2d_engine 源码
    3) linux_5.10: defconfig edge_wevb_emmc -> build_kernel
       -> build_osdrv 2d_engine -> a2_release.sh
    rsync 到 Github 对应目录
    git add（不 commit）

  阶段 5 - 收尾
    脚本不执行 git commit / git push
    日志: auto_sync_bash/logs/sync_YYYYMMDD_HHMMSS.log

同步后人工提交（必须自行完成）
------------------------------
  cd ../github_release_code_bm1688/<仓库名>
  git status
  git diff --cached
  git commit -m "sync from gerrit a2_release"

  示例:
    cd ../github_release_code_bm1688/fsbl
    git status && git commit -m "sync fsbl from gerrit"

常用场景
--------
  # 同步前先单独整理两侧工作区
  ./sync_gerrit_to_github.sh --repo-prep-only

  # 只同步普通源码，不编 FSBL / 2d_engine
  ./sync_gerrit_to_github.sh --sync --skip-fsbl --skip-2d-engine

  # 本地已手动 repo sync，跳过准备步骤
  ./sync_gerrit_to_github.sh --sync --skip-repo-prep

  # 仅 FSBL（含编译，耗时）
  ./sync_gerrit_to_github.sh --fsbl-only

  # FSBL 已在 Gerrit 编好，只同步 + git add
  ./sync_gerrit_to_github.sh --fsbl-sync-only

  # 仅 2d_engine（双内核编译，耗时很长）
  ./sync_gerrit_to_github.sh --2d-engine-only

  # 2d_engine 已编好，只同步 + git add
  ./sync_gerrit_to_github.sh --2d-engine-sync-only

配置文件 sync_gerrit_to_github.conf
------------------------------------
  GERRIT_DIR / GITHUB_DIR          代码根路径
  LOG_DIR                          日志目录

  REPO_PREPARE_BEFORE_SYNC=true    同步前 repo 准备总开关
  REPO_PREPARE_GERRIT=true         准备 Gerrit 侧
  REPO_PREPARE_GITHUB=true         准备 Github 侧
  REPO_CLEAN_WORKTREE=true         是否 git reset --hard && clean -fdx
  REPO_SYNC_J=4                    repo sync 并行数

  GIT_STAGE_AFTER_SYNC=true        同步后对 Github 执行 git add，不 commit
  SYNC_ONLY_EXISTING=true          不向 Github 添加 Gerrit 独有文件
  DELETE_EXTRA_FILES=false         是否 rsync --delete（慎用）

  GERRIT_DEFCONFIG_FSBL=edge_wevb_emmc
  GERRIT_DEFCONFIG_LINUX_510=edge_wevb_emmc
  GERRIT_DEFCONFIG_LINUX_COMMON=edge_emmc_debian

  MANUAL_EXCLUDE_PATHS=( "sophliteos" )   手动排除的 Github 路径

关闭同步后 git add:
  GIT_STAGE_AFTER_SYNC=false

关闭 Github 侧 repo 准备:
  REPO_PREPARE_GITHUB=false

注意事项
--------
  1. repo forall 的 git clean -fdx 会删除未提交修改，运行前请备份重要本地改动。
  2. FSBL、2d_engine 编译依赖 Gerrit 完整构建环境，请预留足够时间和磁盘。
  3. sophliteos 等仅 Github 有的仓库会自动跳过。
  4. 本工具不会 git commit，也不会 git push。
  5. 旧版 sync_repos.sh / sync_fsbl.sh 与本工具独立，以本脚本为准。

================================================================================
