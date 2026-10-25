# Unraid GPU Unlock 开发设计

日期：2026-10-25。本文仅设计开发工作，不执行服务器变更。

## 目标与已确认条件

开发独立的 `gpu-unlock` Unraid 插件，复用 Zagitta/gpu-unlock 内核模块，对用户选定的受支持 GPU 在 NVIDIA 驱动接管之前解锁。NVIDIA Driver 插件继续负责 NVIDIA 驱动及容器工具包。

首个验证环境为 HomeMonster：Unraid 7.3.3、Linux `6.18.54-Unraid`、x86_64。用户已确认 NVIDIA 组件版本问题修复，开发不再以历史版本冲突为故障前提。

| PCI 地址 | PCI ID | 型号 | 首版行为 |
|---|---|---|---|
| `0000:c5:00.0` | `10de:1e07` | RTX 2080 Ti | 显示为不支持，不允许选中 |
| `0000:c8:00.0` | `10de:1e07` | RTX 2080 Ti | 显示为不支持，不允许选中 |
| `0000:cc:00.0` | `10de:2206` | RTX 3080 | 可选择解锁 |
| `0000:cd:00.0` | `10de:2206` | RTX 3080 | 可选择解锁 |

显存容量、改卡情况和当前实际驱动版本在开发基线采集中记录，不从 PCI ID 推断。

首版只承诺经过实机验证的上述环境。其他内核必须有对应构建和验证记录后才标记支持；受支持 PCI ID 不等于对应板卡已经实测。

## 范围

- 完成两张 3080 的开机解锁、原版 NVIDIA 驱动接管和容器可用性验证。
- 提供设置页：选卡、保存下次启动配置、查看逐卡结果、下载日志、关闭解锁。
- 对当前内核分发预编译 `.ko` 与运行所需固件，服务器不安装 DKMS 或编译工具链。
- 保持上游解锁算法；仅在实际编译失败且定位到内核 API 差异时加入最小补丁并记录来源。
- 不增加在线强制解绑、在线重置、自动跑分、自动重启、虚拟机直通适配或多发行版安装器。
- 不维护 NVIDIA 驱动版本选择器，不修改其容器运行时配置，不将 NVIDIA Driver 项目整体 fork 为新插件。
- 首次安装、改选 GPU、关闭功能按“下次启动生效”设计；不承诺卸载模块立即恢复锁定状态。

## 架构与启动时序

推荐路线是独立插件、按内核构建的二进制包和一处明确的启动协调入口。持久文件保存在 `/boot/config/plugins/gpu-unlock/`，运行脚本和状态保存在 RAM 文件系统。

```text
持久化启动配置恢复
  → 延后受控路径中的 NVIDIA 早期加载
  → 恢复 gpu-unlock 模块、固件与配置
  → 确认目标 GPU 尚未绑定驱动
  → 同步执行 gpu_unlock
  → 记录每张卡的实际结果
  → 按现有 NVIDIA Driver 的安装流程加载 NVIDIA
  → 完成必要的 CDI 生成
  → 正常启动 Docker / 工作负载
```

此处的“延后早期加载”是需要实测实现的集成工作，不是已经成立的前提。10 月 23 日的启动日志显示 NVIDIA 在普通插件安装前已接管 GPU；版本修复后的配置仍需采集当前加载入口。不能据旧日志推断当前 NVIDIA 一定来自自定义 bzmodules、initramfs 或某个特定脚本。

### 启动方案的决策规则

1. 首先检查实际启动文件、模块来源、modprobe 配置、rc 脚本、`/boot/extra`、现有 NVIDIA Driver 插件。输出唯一一份当前启动链记录。
2. 若早期接管来自 udev 的模块别名自动加载，优先使用插件自己的持久化 modprobe 配置延后 NVIDIA 自动加载，再在插件阶段完成解锁与显式驱动加载。Unraid 官方说明支持早期恢复 `config/modprobe.d`。
3. `blacklist` 只能抑制别名自动加载，不能作为拦截显式 `modprobe nvidia`、依赖加载或 `insmod` 的保证。发现这些入口时，应先确定并调整实际入口；不反复叠加 blacklist、softdep 和 install 包装器。
4. 普通插件阶段顺序只解决阶段内的先后。若修复后的服务器已不再早期加载 NVIDIA，仍需确认 NVIDIA Driver 安装分支、已存在模块分支及驱动包安装脚本的行为。
5. 首版优先不修改系统 bz* 镜像。如果实机只能在普通插件之前完成解锁，则交付启动链分析与独立的早期加载设计修订，不把未经验证的镜像重打包机制塞进首版。

协调入口必须覆盖 NVIDIA Driver 的两种情况：需要安装驱动包时，以及 `modinfo nvidia` 已能找到模块时。后一种情况不代表驱动已经加载。解锁、驱动加载和 CDI 生成的顺序需逐项确认；不能用 `nvidia-smi` 触发初始化来提前探测未解锁的 GPU。

接入点验收还必须覆盖失败后的加载阻断：出现上游明确要求关机断电的故障时，后续 NVIDIA Driver 插件及其驱动包安装脚本不能继续显式加载 NVIDIA 或生成 CDI。`rc.local` 不会因前一个插件失败而停止安装后续插件，因此仅让 `gpu-unlock-control boot` 返回失败或不调用 NVIDIA 不足以满足要求。启动链记录必须说明实际阻断入口；若选定入口只能保证成功路径的顺序，先形成明确的集成接口修订，再进入启动协调实现。

不直接采用 `softdep nvidia pre: gpu_unlock` 作为核心方案，上游明确指出该规则可能与其他软件的 softdep 冲突。也不把开机后 `/boot/config/go` 中单独运行解锁当作可用方案。

### 与现有 NVIDIA 插件的边界

先验证它实际拥有的加载入口，再选择最少的集成改动：已有入口可协调时直接衔接；如需一个小型上游集成点，先明确该接口，不静默改写第三方 `.plg`。开发不同时维护多套启动实现。

若 NVIDIA 包已被现有插件安装且驱动未加载，协调入口需显式加载驱动；若现有插件会自行加载，则解锁必须已完成。CDI 应在驱动可用后由其现有流程生成，不复制维护整套 NVIDIA Driver 安装器。

## 包、配置与接口

构建产物：

```text
gpu-unlock.plg
gpu-unlock-ui-<插件版本>-x86_64-1.txz
gpu-unlock-kmod-<上游版本>_6.18.54_Unraid-x86_64-1.txz
gpu-unlock-firmware-<固件资源版本>-noarch-1.txz
```

软件包遵循 Slackware 的 `NAME-VERSION-ARCH-BUILD.txz` 格式，包名分别为 `gpu-unlock-ui`、`gpu-unlock-kmod`、`gpu-unlock-firmware`；末尾 `1` 为初始构建号，同版本重新打包时递增。版本字段内部的连字符转换为下划线，仅用于文件名，不改变实际内核版本或安装路径。

内核包按完整 `uname -r` 匹配，包含 `gpu_unlock.ko`；固件包安装到 `/lib/firmware/gpu-unlock/<资源版本>/`，资源路径必须与模块声明一致。固件版本与宿主 NVIDIA 驱动版本分别记录，不要求二者版本号相同。

持久配置只保留首版需要的两个字段：

```ini
enabled="no"
targets="0000:cc:00.0,0000:cd:00.0"
```

安装后默认未启用；选卡列表可预选本机两张受支持的 3080，但只有用户保存启用后才安排下一次启动执行。保存只改变下次启动配置，不触发在线解锁。

模块调用的接口示意：

```bash
modprobe gpu_unlock targets=0000:cc:00.0,0000:cd:00.0
```

这利用模块已提供的参数接口，首版不因此要求修改 Syslinux 或 GRUB 参数。实际入口由启动链验证确定。

最小脚本接口：

```text
gpu-unlock-control inspect       只读输出当前 GPU、绑定驱动、模块及包状态
gpu-unlock-control prepare-boot  按已验证方案准备下一次启动
gpu-unlock-control boot          启动协调；交互页面不调用
gpu-unlock-control status        输出当前启动记录
gpu-unlock-control disable       关闭下一次启动的解锁并撤销自有启动配置
```

网页保存通过 Unraid 现有 PHP / CSRF 机制调用固定动作；配置文件按数据解析，不用 shell `source` 执行。无需常驻服务。

## 结果判定与失败行为

状态页按每张卡分别显示“未启用、等待下次启动、已解锁、已被驱动占用而跳过、解锁失败”，不使用一个全局成功标志覆盖多卡结果。

上游 `gpu_unlock_init()` 在部分逐卡失败后仍返回 0，所以 `modprobe` 成功不足以证明解锁成功。控制脚本只解析本次调用新增、且带目标 PCI 地址的内核日志，记录实际结果。运行记录包括 boot ID、目标 PCI 地址、模块版本、内核版本与结果；boot ID 仅用来区分重启，不计算额外指纹。

- 缺少匹配内核包或尚未触碰硬件：标记本次跳过解锁；仍走正常 NVIDIA 加载路径，不能让持久化延迟规则导致四张卡永远不加载。
- 目标已绑定驱动：标记跳过，不在线解绑或重试。
- 模块已尝试解锁且失败：保留原始日志；不进行第二次复位、卸载重载或自动重试。开发实机验证在这里停止性能测试。
- 上游明确记录需要关机断电的故障：显示该要求，通过已验证的接入点阻止本次启动后续 NVIDIA 加载和 CDI 生成，不自动宣称显卡仍可安全交给 NVIDIA。如果现有接口不能可靠区分这种结果，应先补齐结果接口，不能用 `modprobe` 返回 0 掩盖故障。

关闭或卸载只撤销本插件拥有的启动项、文件和配置，不覆盖原有 modprobe 文件；已经生效的硬件状态不承诺在卸载瞬间复原。若要验证恢复锁定，采用关闭插件后的关机断电基线。

## 构建与发布

使用 Linux x86_64 构建环境，取得目标 Unraid 内核源码、实际 `.config`、启用符号版本时所需的 `Module.symvers`、生成头文件及兼容工具链；不能拿通用发行版的同号内核头文件代替。

保留一个明确的上游源码版本，构建时执行上游固件生成流程。Python 3.14+ 等构建依赖留在构建环境；运行时仅安装模块、五个固件文件和插件脚本。遵循上游已有的资源校验机制，不另建没有消费者的校验或指纹系统。

首个产物用于个人实机验证。公开发布前，根据上游 `firmware/NOTICE.md` 整理源码、许可证及固件分发方式；该事项不影响本地构建验证。GitHub Releases / Community Applications 发布为后续里程碑，不在单机验证前承诺支持范围。

## 验收

| 阶段 | 必须观察的结果 |
|---|---|
| 启动接入 | gpu_unlock 操作期间两张 3080 未绑定 NVIDIA；解锁完成后才接管 |
| 功能 | 两张 3080 分别报告解锁成功；两张 2080 Ti 未成为解锁目标 |
| 驱动 | 四张卡均在 nvidia-smi 可见，现有 GPU 容器可正常运行 |
| 结果可信 | 一卡成功、一卡失败时，页面和日志准确区分，不报全局成功 |
| 失败阻断 | 需断电故障的日志 fixture 覆盖两种 NVIDIA 安装分支；本插件返回后继续执行后续插件阶段，仍无 NVIDIA 加载或 CDI 生成 |
| 重启 | 再次冷启动可按配置重新解锁；页面不复用上次启动的成功记录 |
| 内核升级 | 缺少新内核包时跳过解锁并保留正常 GPU 使用路径 |
| 关闭与卸载 | 插件自有启动改动可撤销，正常 NVIDIA 加载恢复 |
| 收益 | 相同功耗与负载下分别记录单卡 GEMM、实际 AI prefill / decode；输出满足该工作负载的正确性标准 |

首轮优先选一张 3080验证完整启动与驱动接管，再扩展到两张。已有两张同 PCI ID 卡时始终按完整 PCI 地址选卡，不使用会同时命中两卡的 vendor:device 绑定规则。

## 资料

- GPU Unlock 原理、支持型号、启动要求：https://github.com/Zagitta/gpu-unlock
- 模块入口及逐卡结果：https://github.com/Zagitta/gpu-unlock/blob/main/kernel/gpu_unlock/main.c
- 构建入口：https://github.com/Zagitta/gpu-unlock/blob/main/kernel/gpu_unlock/Makefile
- 固件构建：https://github.com/Zagitta/gpu-unlock/blob/main/firmware/README.md
- 固件分发说明：https://github.com/Zagitta/gpu-unlock/blob/main/firmware/NOTICE.md
- NVIDIA Driver 插件：https://github.com/unraid/unraid-nvidia-driver/blob/master/nvidia-driver.plg
- Unraid 插件与 go 执行顺序：https://github.com/unraid/webgui/blob/master/etc/rc.d/rc.local
- Unraid 模块 overlay 与早期 modprobe 配置：https://docs.unraid.net/unraid-os/release-notes/6.9.0/
- Slackware 软件包命名：https://docs.slackware.com/howtos:slackware_admin:building_a_package
