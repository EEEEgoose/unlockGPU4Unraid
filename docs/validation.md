# 验证记录

只记录实际观察到的结果。未完成的项目保持“待验证”，不从 PCI ID 或模拟测试推断板卡结论。

## 构建（Task 2）

| 项目 | 结果 |
|---|---|
| 上游源码 | `Zagitta/gpu-unlock` 1.0.0，commit `af28cbbfd3d922a659227ecfb7369adfd924cf03`（2026-10-24） |
| 固件资源 | `gpu-unlock/610.43.03/` 下 5 个文件（`unlock_610.c` 中的 `MODULE_FIRMWARE`） |
| 构建环境 | 2026-10-25，验证服务器上的临时 `archlinux:latest` 容器（`build/unraid-container.sh`）：gcc 16.2.1 20260810、GNU ld 2.47、Python 3.14.8；宿主机未安装工具链 |
| 内核树 | kernel.org `linux-6.18.54.tar.xz`（清华镜像，sha256 校验通过），加上 `/usr/src/linux-6.18.54-Unraid` 中的 10 个补丁（6 处 fuzz/offset，全部成功）、`drivers/md` 中的 Unraid 文件和 `config`；`olddefconfig` 后与 Unraid 配置一致，差异仅限编译器版本（160201 对 160200）和 Rust 探测项；`modules_prepare` |
| 符号 | 内核未开启 `CONFIG_MODVERSIONS` 和模块签名，因此不需要 `Module.symvers`；模块导入的 61 个符号全部能在 `System.map` 中找到对应的 `__ksymtab_*` 导出项 |
| vermagic | `6.18.54-Unraid SMP preempt mod_unload`，与运行中的 `nvidia`、`zfs` 模块一致 |
| 固件 | `modinfo -F firmware` 列出的 5 个路径与包内 `lib/firmware/gpu-unlock/610.43.03/` 一一对应；输入包经上游 SHA-256 校验 |
| 上游测试 | `make test` 5 项通过 |
| 产物 | `gpu-unlock-kmod-1.0.0_6.18.54_Unraid-x86_64-1.txz`，sha256 `06e2e1eb4f0c922c6b6c9e9579a4732db77a952a444f00d40542a36f42044d40`<br>`gpu-unlock-firmware-610.43.03-noarch-1.txz`，sha256 `481f050082fc96ca3f7d3e03729a531a9ae7e26d41c7e0817d5271bbc2472d1a`<br>位于服务器 `/mnt/zpool/build/gpu-unlock/out/` |
| 补丁 | 无（上游源码未改动） |
| 按教程重新编译 | 2026-10-25，在空目录中按 `docs/build-docker.zh-CN.md` 第 1–2 步执行：从 GitHub 下载 `main`（`fa9b030`），使用镜像和代理运行 `unraid-container.sh`，`BUILD_EXIT=0`，一次得到 kmod、firmware、ui 三个包。与上面的产物相比，包内的 `gpu_unlock.ko`、5 个固件文件和许可文件 sha256 逐一相同；整包 sha256 不同，只是因为 tar 记录的文件时间不同 |
| 运行内核加载 | 2026-10-25，在运行中的 `6.18.54-Unraid` 上不带 `targets` 执行 `insmod`：返回 0，`targets=(null)`，没有新增内核日志（没有未解析符号、vermagic、taint 告警），也没有触碰显卡；随后 `rmmod` 返回 0。四张 GPU 的状态与显存占用与加载前相同 |

## 编排测试（Task 3）

2026-10-27，macOS bash 3.2：`bash tests/test-boot.sh` 78 项、`bash tests/test-status.sh` 21 项全部通过（含 Turing、双模块，以及按 UUID 选卡的型号与 UUID 核对场景）。
另做了变异检查：去掉阻断规则、去掉新增日志边界、去掉断电判据，测试分别报告 8、3、8 项失败。
这些测试只验证脚本编排和结果解释，不能证明硬件解锁成功。

## 启动链前置确认

见 `boot-integration.md` 第 4 节。全部确认前不进行实机冷启动。

## 实机（Task 4）

| 阶段 | 结果 |
|---|---|
| 解锁前基线（GEMM 与 strata 的 qwen3.8-flash-next，功耗按 `GPU-nvidia-smi-setting`） | 待验证（解锁前未测，需关闭插件后冷启动补测） |
| 关闭状态启动（16:52，boot `7364f375`） | 插件在 rc.local 中排在 `fix.common.problems` 之后、`gpustat`/`nvidia-driver` 之前安装；未启用，没有屏蔽规则；NVIDIA 照常早期加载；状态记录目标为空 |
| 两张 3080 同时启用（17:07 重启，非断电冷启动，boot `99b9b274`） | udev 冷插（17:07:40）时没有加载 nvidia；`gpu-unlock.plg`（17:08:52）一次调用 `modprobe gpu_unlock targets=0000:cc:00.0,0000:cd:00.0`；`cc`、`cd` 在 122.30 s 报告 `gpu_unlock: unlocked`，post-FLR 读回 `SS0=88888888 SS1=00000008`；`NVRM: loading 615.71.09` 在 130.23 s，之后 nvidia-drm 依次初始化四张卡；四张卡都绑定 `nvidia`，容器重新占用显存；本次启动没有 Xid；页面/状态记录两卡均为 `unlocked` |
| 原计划“先单卡再双卡” | 用户直接选择了两张卡，单卡阶段跳过 |
| 再次冷启动、关闭后冷启动 | 待验证 |
| 解锁后 GEMM（boot `99b9b274`，运行 `GPU-nvidia-smi-setting` 后 3080 为 240 W，strata 已停止） | `bench/gemm.py`，8192³，5 次中位数：`cc` FP16 95.74、BF16 97.68、TF32 46.00 TFLOPS；`cd` FP16 93.81、BF16 96.68、TF32 46.21 TFLOPS。按 3080 规格折算到实测平均频率，比未解锁理论上限高 88–94%。解锁前基线未测 |
| strata qwen3.8-flash-next prefill/decode | 待验证 |
| 显存容量 | 两张 RTX 3080 均为 20480 MiB（改装 20 GB 版），功耗上限 240 W；两张 2080 Ti 为 22528 MiB、190 W（2026-10-25 `nvidia-smi`） |
| 内核升级后启动（2026-10-27，Unraid 7.3.4，`6.18.58-Unraid`，NVIDIA 615.78.08，boot `9f470a5c`） | 插件已关闭、没有屏蔽规则；插件照常安装，日志为 `no module or firmware package for kernel 6.18.58-Unraid; unlock skipped`；NVIDIA 正常加载四张卡 |
| 从 GitHub 安装 `2026.10.27` | 经代理执行 `plugin install <pluginURL>`：下载 plg 与 Release 中的 UI 包，U 盘缓存的包 MD5 为 `47d78b05a28af7ac9cf6045285430662`，与 plg 一致；旧的 `2026.10.25a` UI 包被清除；`plugin check` 返回 `2026.10.27` |
| `6.18.58-Unraid` 的模块包（2026-10-27，两个项目同一次容器编译） | 内核配置与 Unraid 一致（仅编译器版本与 Rust 探测项不同）。gpu-unlock `af28cbb`：上游测试 5 项通过，导入 61 个符号全部导出，vermagic `6.18.58-Unraid SMP preempt mod_unload`，固件 5 个。turing-unlock `417f333`（2.0.0）：上游无测试，导入 57 个符号全部导出，vermagic 相同，固件 6 个（含 `sec2_bl_tu102.bin`），两者共用同一份 NVIDIA 610.43.03 输入 |
| PCI 地址变化（2026-10-27） | 升级到 Unraid 7.3.4 后重启，四张卡的地址对调：`c5`/`c8` 变为 RTX 3080（10de:2206，子系统 10de:146d），`cc`/`cd` 变为 RTX 2080 Ti（10de:1e07，子系统 10de:12fa）。当前 UUID：`c5` GPU-377334bd-f8ea-4c2b-ac56-8a5653fdb110、`c8` GPU-6147fd8d-fdcf-798a-5e41-9f09d0798190、`cc` GPU-6b9b2810-afad-5c38-52e9-0949330f9bd6、`cd` GPU-3b9ff912-a9d6-7655-9bf9-6e6fb289e5c6。四张卡均无 PCIe 设备序列号，同型号两张卡的 PCI ID、子系统 ID 和 VBIOS 版本相同。本表此前出现的 `cc`、`cd` 均指当时的两张 RTX 3080。由此改为按 UUID 选卡 |
| Turing（两张 RTX 2080 Ti 22GB，`10de:1e07`）实机解锁 | 待验证；turing-unlock 作者仅在 Dell RTX 2080 Ti 22GB + 驱动 575.51.03 上测试，本机驱动为 615.78.08 |
