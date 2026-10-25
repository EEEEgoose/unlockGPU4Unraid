# 启动接入点（Task 1）

采集日期：2026-10-25。数据来源：通过 Unraid API（只读）读取的
`/var/log/syslog.1`（10 月 23 日 11:06 CST 启动，即当前运行中的这次启动）、`installed_unraid_plugins`、`info`，
以及服务器所用 NVIDIA 插件的公开源码。该 API 不提供命令执行和任意文件读取，第 4 节列出仍需在服务器终端确认的项目。

## 1. 当前基线

| 项目 | 值 | 来源 |
|---|---|---|
| Unraid / 内核 | 7.3.3 / `6.18.54-Unraid`，x86_64 | `info` |
| 内核命令行 | `BOOT_IMAGE=/boot@/bzimage unraiduuid=… amd_iommu=off` | syslog.1:1 |
| GPU | `c5:00.0`、`c8:00.0` = `10de:1e07`；`cc:00.0`、`cd:00.0` = `10de:2206` | syslog.1:436–542 |
| NVIDIA 插件 | **fork** `EEEEgoose/unraid-nvidia-driver-zh`，名称仍为 `nvidia-driver`；启动时 `2026.10.23b`，15:54 在线更新为 `2026.10.23c` | syslog.1:2512, 9469 |
| 已修复的历史问题 | 早期加载的内核模块 615.71.09 与插件阶段的用户态 615.78.08 不一致（820 条 `NVRM: API mismatch`）；`2026.10.23c` 修复“启动目录混装两套驱动” | syslog.1:2518 起；fork commit `0f8ea9e` |

## 2. 实际加载链

```text
rc.S / rc.M（rsyslogd 启动前，日志仅有内核环形缓冲回放）
  Unraid 启动扫描安装 /boot/config/plugins/nvidia-driver/packages/<内核>/ 中的驱动包   ← 由 fork README 与 commit 0f8ea9e 推断
  rc.udev: udevadm trigger → udevd 按 PCI 别名自动加载 nvidia、nvidia_modeset、nvidia_drm
           （syslog.1:1481–1547；告警栈 “Comm: udevd … __do_sys_finit_module”）
           → 四张卡全部被 nvidia 接管
rc.local（11:06:54 起）
  /boot/extra → dynamix.unraid.net.plg（优先）→ 其余 *.plg 按 glob 顺序
    … fix.common.problems → gpustat → ipmi → … → mft-tools → nvidia-driver（11:07:55）→ …
  nvidia-driver.plg：`modinfo nvidia` 命中 → 不执行 modprobe，仅 activate + generate_cdi（nvidia-ctk）
emhttpd 启动阵列 → rc.docker start（11:26:23）
```

结论：早期接管属于设计文档决策规则 2 的“udev 别名自动加载”，发生在任何普通插件之前。仅靠插件顺序无法让解锁先于 NVIDIA。

## 3. 选定接入点

唯一一套实现，全部由 `gpu-unlock-control` 管理：

| 时刻 | 动作 | 文件 |
|---|---|---|
| 用户保存“启用” | `prepare-boot` 写入持久规则，对 `nvidia nvidia_uvm nvidia_modeset nvidia_drm nvidia_peermem` 逐个 `blacklist`，让下一次启动的 udev 不再按别名加载其中任何一个（只屏蔽 `nvidia` 不够：别名命中 `nvidia_drm` 时，nvidia 会作为依赖被拉起） | `/boot/config/modprobe.d/gpu-unlock.conf`（本插件独占） |
| 下次启动 rc.S | Unraid 将 `config/modprobe.d` 早期恢复到 `/etc/modprobe.d`；驱动包照常安装；udev 跳过上述模块 | — |
| rc.local，`gpu-unlock.plg` | 安装 UI/kmod/固件包 → `depmod` → `gpu-unlock-control boot`：检查目标未绑定 → 一次 `modprobe gpu_unlock targets=…` → 解析新增内核日志 → 正常时按各 NVIDIA 显卡的 `modalias` 用 `modprobe -R` 解析出 udev 原本会加载的 nvidia 模块（排除 `nouveau`、`nvidiafb`）并逐个显式加载 | `/var/run/gpu-unlock/status.json`、`/var/log/gpu-unlock.log` |
| rc.local，`nvidia-driver.plg` | 两个分支都在本插件之后：已有模块分支只生成 CDI；安装分支执行 `modprobe nvidia` 后生成 CDI | 第三方，未改动 |

两个分支的覆盖方式：

- **模块已存在**（当前实际分支）：解锁 → 本插件 `modprobe nvidia` → nvidia-driver 的 `generate_cdi`。
- **需要安装驱动包**：此时 `modinfo nvidia` 不存在，本插件只记录，不加载 → nvidia-driver `installpkg; depmod; modprobe nvidia` → CDI。解锁已在其之前完成。

需断电故障的阻断：`boot` 在新增日志中发现 `firmware did not stop; keeping its DMA buffers until power off`、
`card already initialised since power on (WPR2 enabled); power off first`，或其他带目标地址的 `power off` 行时，写入仅存在于本次启动的

```text
/etc/modprobe.d/gpu-unlock-block.conf
install nvidia /bin/false
install nvidia_uvm /bin/false
install nvidia_modeset /bin/false
install nvidia_drm /bin/false
install nvidia_peermem /bin/false
```

此后 nvidia-driver 安装分支的 `modprobe nvidia`、已有模块分支中 `nvidia-ctk`/NVML 经 `nvidia-modprobe` 触发的加载都会失败，因此不会加载 NVIDIA，也不会生成 CDI。本插件返回后 rc.local 照常继续执行，阻断不依赖本插件的返回值。重启后该文件随 RAM 文件系统消失。

不会使 NVIDIA 永久不加载的保证：

- 缺少当前内核的 kmod 包、目标已绑定、模块加载失败或普通解锁失败时，`boot` 都会显式 `modprobe nvidia`。
- 即使本插件完全没有运行，nvidia-driver 的 `nvidia-ctk` 也会通过 `nvidia-modprobe` 显式加载驱动，`blacklist` 不拦截显式加载。
- `disable` 和卸载会删除 `/boot/config/modprobe.d/gpu-unlock.conf` 及其在 `/etc/modprobe.d` 的副本。

## 4. 服务器终端确认

2026-10-25 用户在服务器终端执行了下面这组命令，结果如下：

| 项目 | 结果 |
|---|---|
| modprobe 规则 | 与 nvidia 有关的只有 `blacklist nvidiafb`；没有 softdep、install、options |
| udev 规则 | `/etc/udev/rules.d`、`/lib/udev/rules.d` 中没有 nvidia |
| modprobe.d | `/etc/modprobe.d` 中有 U 盘 `config/modprobe.d` 的副本（i915、ixgbe、mlx4_core、zfs、`nvidia.conf.bak`），证实早期恢复；`.bak` 不生效；没有 `gpu-unlock.conf` 同名文件 |
| rc 脚本 | `rc.S`/`rc.M` 中没有匹配；驱动包早期安装的位置未找到。接入点拦截的是 udev 别名加载，与驱动包在哪个脚本安装无关 |
| 驱动包 | `packages/6.18.54/` 只有 `nvidia-615.71.09-6.18.54-Unraid-1.txz`，`cache/` 为空 |
| 插件顺序 | `LC_COLLATE=C`：`gpu-unlock.plg` 排在 `gpustat.plg`、`nvidia-driver.plg` 之前。排在前面的插件即使触发了 NVIDIA，结果也只是“已被驱动占用而跳过”，不会对已绑定的卡执行解锁 |
| 已加载模块 | `nvidia`、`nvidia_modeset`、`nvidia_drm`（无使用者）、`nvidia_uvm`（运行时由 nvidia-modprobe 加载） |

模块别名（`modinfo -F alias`、`modprobe -R`，2026-10-25 确认）：

| 模块 | PCI 别名 |
|---|---|
| `nvidia` | `pci:v000010DEd*sv*sd*bc03sc00i00*`、`bc03sc02`、`bc06sc80`；另有 `char-major-195-*` |
| `nvidia_drm` | 与 `nvidia` 相同的三条 PCI 别名 |
| `nvidia_modeset`、`nvidia_uvm` | 无 |

`modprobe -R` 对 `0000:cc:00.0` 解析出 `nouveau nvidia_drm nvidia`。可见早期加载链是：udev 按别名同时加载 `nvidia` 和 `nvidia_drm`，`nvidia_drm` 再把 `nvidia_modeset` 作为依赖拉起。
因此只屏蔽 `nvidia` 不够，需要屏蔽全部 nvidia 模块（第 3 节）。解锁后由 `boot` 加载 `nvidia`、`nvidia_drm`，与原有接管方式一致；`nouveau` 已由系统的 `nouveau.conf` 屏蔽，本插件也不会加载它。

首次冷启动时，用 `dmesg | grep -E 'NVRM: loading|gpu_unlock'` 确认 `NVRM: loading` 出现在 `gpu_unlock: unlocked` 之后。

原始采集命令：

```bash
modprobe --showconfig | grep -E '^(blacklist|softdep|install|options) .*nvidia'   # 是否有让其他模块依赖拉起 nvidia 的规则
grep -rn nvidia /etc/udev/rules.d /lib/udev/rules.d 2>/dev/null                    # 是否有 udev RUN+="modprobe …" 显式加载
ls -l /boot/config/modprobe.d /etc/modprobe.d                                      # 现有自定义规则，避免同名
grep -n -E 'packages|installpkg|upgradepkg|modprobe.d' /etc/rc.d/rc.S /etc/rc.d/rc.M /etc/rc.d/rc.S.cont 2>/dev/null   # 驱动包早期扫描与 modprobe.d 恢复的位置和先后
ls -R /boot/config/plugins/nvidia-driver/packages | head
locale; ls /boot/config/plugins/*.plg                                              # rc.local glob 顺序：gpu-unlock.plg 必须早于 gpustat.plg、nvidia-driver.plg
lsmod | grep -E '^nvidia'                                                          # 早期一并加载的模块集合
```

还需确认：

- gpustat 插件安装阶段只检查 `nvidia-smi` 是否存在，不执行它（syslog.1:2311 的输出与此一致）。
- `GPU-nvidia-smi-setting` 这个 User Script 不在启动阶段运行。

## 5. 启用与撤销

启用（下次启动生效）：设置页保存 → 写 `settings.cfg` → `gpu-unlock-control prepare-boot` → 写 `/boot/config/modprobe.d/gpu-unlock.conf`。前提是持久存储中已有当前内核的 kmod 包和固件包。

撤销：设置页“关闭解锁”或卸载插件 → `gpu-unlock-control disable` → `enabled="no"`，删除上述文件及 `/etc/modprobe.d/gpu-unlock.conf`。已经生效的硬件状态不承诺立即恢复；要恢复锁定状态，需关闭插件后关机断电。

手动恢复（WebUI 不可用时）：删除 U 盘上的 `config/modprobe.d/gpu-unlock.conf`，或删除 `config/plugins/gpu-unlock.plg`，然后重启。
