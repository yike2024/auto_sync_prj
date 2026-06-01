# Gerrit ↔ Github 仓库对比分析表

## 📊 概览

| 项目 | Gerrit (a2_release) | Github (bm1688) |
|------|---------------------|-----------------|
| **总仓库数** | 28 个 | 22 个 |
| **共同仓库** | - | 18 个 |
| **仅 Gerrit 有** | 6 个 | - |
| **仅 Github 有** | - | 4 个 |

---

## 🔗 详细的仓库映射关系

### ✅ 共同仓库 (路径相同，可以直接同步)

这些仓库在两个代码库中路径完全一致，可以直接同步文件内容：

| # | Gerrit 仓库名 | Github 仓库名 | 同步路径 | Gerrit 分支 | Github 分支 |
|---|---------------|---------------|----------|-------------|-------------|
| 1 | `cvi_build` | `build` | `build/` | a2_release | bm1688 |
| 2 | `cvitek/buildroot-2021.05` | `buildroot-2021.05` | `buildroot/` | a2_release | bm1688 |
| 3 | `cvi_rtsp` | `cvi_rtsp` | `cvi_rtsp/` | a2_release | master |
| 4 | `fsbl` | `fsbl` | `fsbl/` | a2_release | bm1688 |
| 5 | `host-tools` | `host-tools` | `host-tools/` | master | master |
| 6 | `isp-tool-daemon` | `isp-tool-daemon` | `isp-tool-daemon/` | a2_release | bm1688 |
| 7 | `isp_tuning` | `isp_tuning` | `isp_tuning/` | a2_release | bm1688 |
| 8 | `libsophon` | `libsophon` | `libsophon/` | a2_release | bm1688 |
| 9 | `linux-common` | `linux-common` | `linux-common/` | dev-edge-6.12.61 | linux-6.12.y |
| 10 | `linux_5.10` | `linux_5.10` | `linux_5.10/` | a2_release | bm1688 |
| 11 | `sophon_media` | `sophon_media` | `sophon_media/` | release | master |
| 12 | `tdl_sdk` | `tdl_sdk` | `tdl_sdk/` | a2_release | bm1688 |
| 13 | `u-boot-2021.10` | `u-boot-2021.10` | `u-boot-2021.10/` | a2_release | bm1688 |
| 14 | `cvi_osdrv` | `osdrv` | `osdrv/` | a2_release | bm1688 |
| 15 | `cvi_ramdisk` | `ramdisk` | `ramdisk/` | a2_release | bm1688 |
| 16 | `cvitek/oss` | `oss` | `oss/` | master | master |
| 17 | `cvi_middleware` | `middleware` | `middleware/` | a2_release | bm1688 |
| 18 | `cvitek/isp-tool-daemon` | `isp-tool-daemon` | `isp-tool-daemon/` | a2_release | bm1688 |

---

### 📁 子目录映射仓库

这些仓库被映射为其他仓库的子目录：

#### 1️⃣ `libsophav` - 双路径映射 ⭐

这是同一个仓库，但需要同步到两个不同位置：

| 仓库名 | 路径1 | 路径2 | 说明 |
|--------|-------|-------|------|
| `libsophav` | `libsophon/libsophav/` | `sophon_media/libsophav/` | 同一个仓库，两个父目录 |

**同步策略**：
- 从 Gerrit 的 `libsophon/libsophav/` 同步到 Github 的 `libsophon/libsophav/`
- 从 Gerrit 的 `sophon_media/libsophav/` 同步到 Github 的 `sophon_media/libsophav/`

#### 2️⃣ `isp` - 子目录映射

| Gerrit 路径 | Github 路径 | 说明 |
|-------------|-------------|------|
| `middleware/v2/modules/isp/` | `middleware/v2/modules/isp/` | 作为 middleware 的子模块 |

#### 3️⃣ `SensorSupportList` - Gerrit 特有

| Gerrit 路径 | 说明 |
|-------------|------|
| `middleware/v2/component/SensorSupportList/` | 仅 Gerrit 有，需要复制 |

---

### 📥 仅 Gerrit 有的仓库 (需要复制到 Github)

| # | 仓库名 | Gerrit 路径 | 说明 |
|---|--------|-------------|------|
| 1 | `opensbi` | `opensbi/` | RISC-V 固件 |
| 2 | `cvitek/SensorSupportList` | `middleware/v2/component/SensorSupportList/` | 传感器支持列表 |
| 3 | `nvr_edge` | `frameworks/nvr_edge/` | NVR Edge 框架 |
| 4 | `cvitek/mediapipe` | `mediapipe/` | MediaPipe |
| 5 | `sophgo-develop-docs` | `sophgo-develop-docs/` | 开发文档 |
| 6 | `pytest` / `pytest/testcases` | `pytest/` / `testcases/` | 测试框架和用例 |

---

### 📤 仅 Github 有的仓库

| # | 仓库名 | Github 路径 | 说明 |
|---|--------|-------------|------|
| 1 | `sophliteos` | `sophliteos/` | Sophlite OS (A2 分支) |
| 2 | `manifest_*.xml` | `manifest_*.xml` | Repo 清单文件 |

---

## 🔄 同步策略建议

### 1️⃣ 直接同步 (路径相同)

对于 18 个共同仓库，直接使用 `rsync` 同步文件内容。

### 2️⃣ 子目录同步

对于 `libsophav`、`isp`、`SensorSupportList` 等子目录映射的仓库，需要：
- 分别处理每个映射路径
- 确保父目录存在

### 3️⃣ 新仓库复制

对于 6 个仅 Gerrit 有的仓库，需要完整复制到 Github 目录。

### 4️⃣ 排除处理

同步时需要排除：
- `.git/` 目录
- `.repo/` 目录
- `manifest*.xml` 文件

---

## 📝 附录：仓库名映射表

### Gerrit -> Github 仓库名映射

| Gerrit 仓库名 | Github 仓库名 | 说明 |
|---------------|---------------|------|
| cvi_build | build | 构建系统 |
| cvitek/buildroot-2021.05 | buildroot-2021.05 | Buildroot |
| cvi_osdrv | osdrv | 操作系统驱动 |
| cvi_ramdisk | ramdisk | Ramdisk |
| cvitek/oss | oss | 开源软件 |
| cvi_middleware | middleware | 中间件 |
| cvitek/isp-tool-daemon | isp-tool-daemon | ISP 工具守护进程 |
| cvitek/tdl_sdk | tdl_sdk | TDL SDK |
| cvitek/buildroot-2021.05 | buildroot-2021.05 | Buildroot |
