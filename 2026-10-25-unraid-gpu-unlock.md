# Unraid GPU Unlock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> 上述是 writing-plans 技能要求保留的执行提示。当前会话未提供这两个执行技能；实施时使用实际可用的工作流逐项执行，不把缺失技能当作已安装。本次仅设计，不派发执行或子代理。

**Goal:** 为 HomeMonster 的两张 RTX 3080 开发可验证、可卸载的 Unraid GPU Unlock 插件。

**Architecture:** 独立插件复用上游内核模块与固件，针对完整 Unraid 内核版本构建软件包。先确认并协调真实的 NVIDIA 加载入口，确保解锁先于驱动接管；NVIDIA Driver 插件继续管理 NVIDIA 软件包和容器工具。

**Tech Stack:** Linux kernel Kbuild、Linux x86_64 构建环境、Bash、Unraid PHP 页面、Slackware `.txz`、Unraid `.plg`；固件生成使用上游要求的 Python 3.14+。

**Spec:** `../specs/2026-10-25-unraid-gpu-unlock-design.md`

## Global Constraints

- 首个验证环境为 Unraid 7.3.3、Linux `6.18.54-Unraid`、x86_64。
- 用户已确认 NVIDIA 组件版本问题修复，不追查已修复的历史冲突。
- 解锁目标为 `0000:cc:00.0`、`0000:cd:00.0`；`0000:c5:00.0`、`0000:c8:00.0` 不允许选作解锁目标。
- 首版不在线解绑、在线重置、自动重启或适配虚拟机直通。
- 不以插件排序、blacklist 或 `modprobe` 的成功退出单独证明启动与解锁成功。
- 不修改系统 bz* 镜像作为首版默认路线，不整体 fork NVIDIA Driver 项目。
- 不增加额外哈希、指纹、兼容框架或常驻服务。
- 本次只写设计文档；服务器配置变更、驱动加载和重启属于后续实施。

---

## 文件布局与责任

以下均为计划创建的文件，本次仅创建设计与计划文档。

```text
docs/superpowers/specs/2026-10-25-unraid-gpu-unlock-design.md
docs/superpowers/plans/2026-10-25-unraid-gpu-unlock.md
docs/boot-integration.md                         实机加载链、选定接入点与恢复方法
docs/validation.md                               当前版本的硬件、功能和性能证据
README.md                                        安装、使用、支持范围和卸载
build/build.sh                                   按 KDIR 构建模块和固件包
build/package.sh                                 打包运行脚本与 PHP 页面
gpu-unlock.plg                                   安装、启动恢复、更新和卸载入口
source/usr/local/sbin/gpu-unlock-control          启动协调、检查、状态及关闭
source/usr/local/emhttp/plugins/gpu-unlock/
  GPUUnlock.page                                页面入口
  include/settings.php                          保存选卡与下次启动设置
tests/test-boot.sh                               启动顺序与失败分支的模拟测试
tests/test-status.sh                             日志到逐卡状态的解析测试
tests/fixtures/                                 上述测试实际使用的最小输入
```

构建产物放在 `build/out/`，不把 NVIDIA 固件二进制或访问 Token 提交到源码中。`build/` 不缓存用户服务器的其他配置或凭据。

## Task 1：确认启动接入点

**Files:** 创建 `docs/boot-integration.md`。

**Interfaces:** 输入为实际启动配置和当前 GPU 状态；输出为唯一一条选定的接入路径、明确的 NVIDIA 加载时刻和恢复步骤，供 Task 3 使用。

- [ ] 只读记录当前基线。以下为后续在服务器终端执行的采集命令，不在写计划时执行：

```bash
uname -r
cat /proc/cmdline
cat /proc/driver/nvidia/version
nvidia-smi --query-gpu=name,pci.bus_id,memory.total,driver_version,power.limit --format=csv
modinfo -n nvidia
modprobe --showconfig | sed -n '/nvidia\|gpu_unlock\|nouveau/p'
modprobe -n -v nvidia
ls -l /boot/extra
sed -n '1,240p' /etc/rc.d/rc.S
sed -n '1,240p' /etc/rc.d/rc.S.cont
sed -n '1,280p' /etc/rc.d/rc.local
sed -n '1,160p' /boot/config/go
```

- [ ] 检查服务器实际安装的 NVIDIA Driver `.plg` 及驱动包安装脚本中所有 `modprobe` / `insmod` 调用；记录驱动包是由哪个阶段安装。启动菜单路径以实际启动器为准，不预设 Syslinux。
- [ ] 将早期加载分类为“别名自动加载”或“显式加载”，并按设计文档的决策规则确定一处协调入口。若这些命令无法从当前 MCP 获得，不绕过其日志接口读取任意文件，改用获授权的服务器终端通道或用户提供的命令输出。
- [ ] 逐项说明该入口如何覆盖“驱动包需要安装”和“模块文件已经存在”两个分支：成功时保证解锁、NVIDIA 加载、CDI 生成的顺序；发生明确要求关机断电的故障时，阻止后续 NVIDIA Driver 插件的显式加载及 CDI 生成，不能仅依靠本插件返回失败。若选定入口无法控制后续行为，先形成具体接口修订，再进入 Task 3。
- [ ] 写出准确的自有配置文件路径、启用时变更和撤销步骤。若必须改第三方入口，先形成具体接口修订，不能在 Task 3 静默补丁化第三方插件。

**验证目的：** 检出 NVIDIA 在解锁前接管、需断电故障后仍被后续插件加载，或把“模块文件存在”误判为“驱动已加载”的错误。发生时修正接入路径，未闭合正常顺序和故障阻断前不进入硬件解锁。

**交付：** `docs/boot-integration.md` 能用实际路径和调用顺序解释从启动到 Docker 可用的全过程。若只有更早的启动阶段可满足要求，修订早期加载设计后再继续，不擅自添加第二套启动框架。

## Task 2：构建当前内核的运行包

**Files:** 创建 `build/build.sh`，更新 `docs/validation.md`。

**Interfaces:** 构建脚本接收上游源码目录和已准备好的 `KDIR`；输出 `gpu-unlock-kmod-<上游版本>_6.18.54_Unraid-x86_64-1.txz` 与固件包。包名遵循 Slackware `NAME-VERSION-ARCH-BUILD.txz`；固件包和 `build/package.sh` 生成的 UI 包沿用设计文档中的命名。版本字段内部的连字符改为下划线，仅影响包名；内核匹配仍使用完整 `uname -r`，模块目录仍使用 `6.18.54-Unraid`。

- [ ] 选择一个明确的上游源码版本，记录版本和取得路径；准备与目标内核匹配的源码、配置、生成头文件、符号信息和工具链。
- [ ] 在 Linux x86_64 构建环境执行上游构建入口：

```bash
make -C "$GPU_UNLOCK_SRC/kernel/gpu_unlock" KDIR="$UNRAID_KDIR"
make -C "$GPU_UNLOCK_SRC" ASSETS="$GPU_UNLOCK_ASSETS" assets
modinfo -F vermagic "$GPU_UNLOCK_SRC/kernel/gpu_unlock/gpu_unlock.ko"
modinfo -F firmware "$GPU_UNLOCK_SRC/kernel/gpu_unlock/gpu_unlock.ko"
```

变量由 `build/build.sh` 参数设置，不能依赖开发者本机运行内核。固件生成仅在构建环境运行。

- [ ] 将 `.ko` 放入包内 `/lib/modules/6.18.54-Unraid/extra/`；按模块声明放置五个固件资源，携带上游要求的许可证。`depmod` 在服务器安装阶段执行，不对构建机内核执行。
- [ ] 若编译报错，定位具体 API 差异后作最小修补；将补丁和编译证据一起保留，不预写多内核兼容层。
- [ ] 列出产物内容，核对包名按 Slackware 规则解析后的名称、版本、架构和构建号，以及包内路径与 `MODULE_FIRMWARE` 对应，记录模块 vermagic 与目标内核一致。运行上游测试用于检测解锁源码或固件生成流程在实际补丁后出现的回归；不把模拟测试当作硬件解锁证明。

**验证目的：** 检出包身份或架构字段错位、内核不匹配、未解析符号、固件漏包和路径错误。发生时修正包名、构建输入或包布局，不尝试强制加载。

**交付：** 能在目标环境加载的候选包及其构建记录，尚不标记实机解锁成功。

## Task 3：实现启动协调和逐卡状态

**Files:** 创建 `source/usr/local/sbin/gpu-unlock-control`、`tests/test-boot.sh`、`tests/test-status.sh` 及最小 fixtures；更新 `docs/boot-integration.md`。

**Interfaces:** 按设计实现 `inspect`、`prepare-boot`、`boot`、`status`、`disable`。读取 `settings.cfg`，输出 `/var/run/gpu-unlock/status.json`，追加 `/var/log/gpu-unlock.log`；启动协调只能使用 Task 1 已验证的入口。

逐卡状态记录示例：

```json
{
  "boot_id": "本次/proc/sys/kernel/random/boot_id的值",
  "kernel": "6.18.54-Unraid",
  "targets": [
    {"pci": "0000:cc:00.0", "state": "unlocked"},
    {"pci": "0000:cd:00.0", "state": "failed", "reason": "unlock failed (-16)"}
  ]
}
```

- [ ] 先实现只读 `inspect`，按 `/sys/bus/pci/devices/<BDF>/vendor`、`device`、`driver` 确认选卡；检查当前内核是否有对应模块包。目标以完整 PCI 地址保存，不能改成 vendor:device 级别规则。
- [ ] 先用日志 fixture 验证这个关键行为：同一次调用返回 0，但日志一张卡成功、一张失败时，必须分别得到 `unlocked` 和 `failed`。再实现结果解析；`status` 不得复用其他 boot ID 的记录。
- [ ] 在测试中使用替身命令记录 `unlock`、`nvidia`、`cdi` 三个事件，断言实际顺序；缺少模块包时断言跳过 unlock、仍保留正常驱动加载；已绑定卡断言没有解绑或重复解锁事件。
- [ ] 实现 Task 1 已确定的启动协调逻辑。控制流应满足：

```text
读取配置与当前 boot ID
  → 检查是否启用、包是否匹配、目标是否未绑定
  → 记录本次内核日志边界并执行一次 gpu_unlock
  → 从新增逐卡日志生成结果
  → 按设计中的失败类别决定驱动交接
  → 在 NVIDIA 可用后衔接其现有 CDI 流程
```

- [ ] 对明确要求关机断电的上游错误建立真实日志 fixture；模拟本插件的 `boot` 返回后继续执行 NVIDIA Driver 插件安装阶段，分别覆盖“驱动包需要安装”和“模块文件已经存在”两个分支。即使 `modprobe` 返回 0，也断言均无 `nvidia`、`cdi` 事件，不能仅断言本插件返回失败。正常成功及缺少解锁模块包的路径仍应完成 NVIDIA 加载和 CDI 生成。如果上游日志无法可靠给出所需判据，应在实机试验前定义并补齐最小结果接口，再实现对应解析。
- [ ] 运行两个针对行为的测试脚本：

```bash
bash tests/test-boot.sh
bash tests/test-status.sh
```

**验证目的：** 检出加载顺序错误、多卡误报、旧状态误报及延迟配置导致原有 GPU 使用路径中断。测试模拟脚本编排和结果解释，不模拟解锁算法。

**交付：** 可在候选包安装后执行的命令行版本，尚不依赖 WebUI。

## Task 4：一张卡实机验证，再扩展两张

**Files:** 更新 `docs/validation.md`。

**Interfaces:** 输入为 Task 2 包、Task 3 控制脚本和已验证的启动入口；输出逐卡启动、驱动接管、容器可用性与性能记录。

- [ ] 在解锁前保存一张 3080 的正常工作基线：相同模型、软件版本、功耗限制、输入和正确性判据。基准选择 GEMM 与用户实际使用的 AI 工作负载，不新建通用跑分平台。
- [ ] 先仅选 `0000:cc:00.0`，安装候选包和已记录的启动改动，在约定维护窗口进行冷启动。该步骤实际执行前明确告知四张 GPU 工作负载会中断。
- [ ] 核对本次新增日志中 unlock 在目标卡 NVIDIA 接管前发生；再核对四张卡均被正常识别。遇到实际模块或固件故障，保留记录并停止继续性能测试。
- [ ] 用原有容器运行同一工作负载，记录输出正确性、吞吐、prefill / decode、功耗和是否出现新增 Xid / NVRM 故障。
- [ ] 单卡通过后增加 `0000:cd:00.0`，完成两张卡分别解锁、四张卡正常使用的验证。
- [ ] 再次冷启动验证配置持久性；关闭功能后冷启动验证不再执行解锁、常规驱动加载正常。

**验证目的：** 检出模拟测试无法覆盖的板卡固件不兼容、驱动接管失败、计算错误及无实际收益。收益低时如实记录，不为追求基准数字改功耗设置。

**交付：** 一个已验证的命令行 MVP。未通过此阶段前不做公开支持声明。

## Task 5：封装原生插件和最小设置页

**Files:** 创建 `gpu-unlock.plg`、`build/package.sh`、`GPUUnlock.page`、`include/settings.php`、`README.md`。

**Interfaces:** `.plg` 复用已验证的命令行控制逻辑；页面只调用固定的查看、保存、关闭动作，保存配置后显示下次启动生效。

- [ ] `.plg` 安装 UI、控制脚本和目标内核包；包已缓存时可离线恢复启动。启用之前确认需要的模块和固件均在持久存储中，不在早期启动阶段等待网络下载。
- [ ] 为四张卡显示型号、PCI 地址、支持情况、当前绑定驱动和本次结果。2080 Ti 不提供可保存的解锁选项。
- [ ] 保存 `enabled` 与完整 PCI 地址列表，使用 Unraid 现有 CSRF 校验；读取配置按数据处理。用户调整选卡不触发在线模块操作。
- [ ] 加入“保存下次启动配置”“刷新状态”“下载日志”“关闭解锁”四个必要动作；不提供“立即强制解锁”。
- [ ] 卸载只移除插件自有文件与启动改动；若触及共用启动文件，只移除本插件插入的准确条目，不用整个旧备份覆盖后来配置。
- [ ] 验证缺少新内核包、关闭功能和卸载后均不会因自有延迟规则造成 NVIDIA 永久不加载。缺包路径用编排替身测试，不为测试而实际升级服务器。
- [ ] README 写清当前已实测版本、安装与恢复步骤、逐卡结果含义，以及关闭不等于即时恢复锁定。

**验证目的：** 检出重启后配置丢失、无网络无法恢复、网页误报状态，以及插件撤销不完整。页面布局只需确认可读、动作明确，不增加与实现细节一一对应的低价值测试。

**交付：** 可本地安装、重启生效、关闭和卸载的单机验证版 `.plg`。

## Task 6：整理发布产物

**Files:** 更新 `README.md`、`docs/validation.md`，按实际发布方式加入构建发布配置。

**Interfaces:** 输入为经过实机验证的本地产物；输出为带支持范围和许可证的发布候选。

- [ ] 按完整内核版本组织构建产物，插件找不到匹配包时明确显示本次跳过，不尝试相近内核的 `.ko`。
- [ ] 对照上游固件 NOTICE 确定公开分发内容及许可证随包方式；个人本地固件包不自动视为可公开发布产物。
- [ ] 发布说明只列已验证的 Unraid、内核、板卡和实际收益，区分“PCI ID 支持”与“板卡实测”。
- [ ] 准备 GitHub Releases 下载路径与插件元数据；公开发布和 Community Applications 提交作为独立发布动作执行。

**验证目的：** 检出发布包与已验证产物不一致、下载路径不可用或支持范围夸大。无需重复已经通过且未变化的硬件测试。

**交付：** 可供审阅的发布候选及发布说明。

## 当前交付与实施顺序

本次完成设计和任务拆分。实施顺序固定为 Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6；先交付实机可用的命令行 MVP，再完成插件界面与公开发布。
