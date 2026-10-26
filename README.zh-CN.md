# GPU Unlock for Unraid

[English](README.md) | 简体中文

在 NVIDIA 驱动接管之前，对选定的 Ampere 显卡运行 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)，
解锁 FP16/BF16 指令发射速率。NVIDIA 驱动、容器工具包和 CDI 仍由 NVIDIA Driver 插件负责。

本插件基于 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) 开发，解锁算法与固件生成都来自上游，本插件只负责在 Unraid 上编排开机顺序、记录结果和提供设置页。

## 支持范围

已实测的环境（详见 [docs/validation.md](docs/validation.md)）：

- Unraid 7.3.3，内核 `6.18.54-Unraid`，x86_64，NVIDIA 驱动 615.71.09
- 两张 RTX 3080 20 GB（`10de:2206`，改装显存），开机解锁成功，NVIDIA 正常接管全部四张卡（另有两张 RTX 2080 Ti 不参与解锁）

插件可选的显卡范围与上游一致：GA102/GA103/GA104/GA106 的 GeForce 型号。“上游支持该 PCI ID”不等于“该板卡已实测”。
其他 NVIDIA 显卡（例如 RTX 2080 Ti）会显示为“不可解锁”，不能勾选。
插件只使用与当前 `uname -r` 完全一致的模块包；找不到时，本次启动跳过解锁，NVIDIA 照常加载。

## 实测性能

RTX 3080 20 GB，功耗上限 240 W，驱动 615.71.09，PyTorch 2.13 / CUDA 13.0。
测试为 8192³ 稠密 GEMM，FP16/BF16 使用 FP32 累加，取 5 次中位数，脚本是 [bench/gemm.py](bench/gemm.py)。

| 显卡 | 精度 | 解锁后 | 平均 SM 频率 | 同频未解锁理论上限 | 提升幅度 |
|---|---|---|---|---|---|
| `cc:00.0` | FP16 | 95.74 TFLOPS | 1431 MHz | 49.8 TFLOPS | +92% |
| `cc:00.0` | BF16 | 97.68 TFLOPS | 1445 MHz | 50.3 TFLOPS | +94% |
| `cc:00.0` | TF32 | 46.00 TFLOPS | 1406 MHz | 24.5 TFLOPS | +88% |
| `cd:00.0` | FP16 | 93.81 TFLOPS | 1410 MHz | 49.1 TFLOPS | +91% |
| `cd:00.0` | BF16 | 96.68 TFLOPS | 1449 MHz | 50.4 TFLOPS | +92% |
| `cd:00.0` | TF32 | 46.21 TFLOPS | 1390 MHz | 24.2 TFLOPS | +91% |

提升幅度 = 解锁后 ÷ 同频未解锁理论上限 − 1。

“同频未解锁理论上限”不是实测值，是按 NVIDIA 公布的 RTX 3080 规格，折算到测试时的平均频率得到的：
GeForce 版 FP16/BF16（FP32 累加）为 59.5 TFLOPS、TF32 为 29.8 TFLOPS，均对应 1710 MHz。
解锁后的实测值已经超过这个上限，达到全速理论值的 94–97%。
未解锁的实测基线还没有测；补测之后，这里会换成实测对比。

## 安装

本仓库不分发固件（见下文“固件与许可”），所以模块包和固件包需要你在自己的服务器上用 Docker 编译。
完整步骤见 **[用 Docker 编译模块和固件](docs/build-docker.zh-CN.md)**，简要流程：

1. 在 Unraid 终端下载本仓库，运行 `repo/build/unraid-container.sh <工作目录>`，得到模块包和固件包。
2. 把这两个包复制到 U 盘的 `config/plugins/gpu-unlock/packages/`。
3. 从 `https://raw.githubusercontent.com/EEEEgoose/unlockGPU4Unraid/main/gpu-unlock.plg` 安装插件，可以用 `plugin install` 命令，也可以在 **插件 → 安装插件** 中粘贴地址。UI 包会自动从 GitHub Releases 下载。
4. 打开 **设置 → 实用工具 → GPU Unlock**，勾选要解锁的显卡，“下次启动解锁”选“是”，保存。
5. 冷启动（关机后再开机）。

安装后默认不启用。保存只改变下次启动的配置，不会在线解锁。
插件更新会出现在 **插件** 页面的“检查更新”中；模块包只在 Unraid 升级内核后才需要重新编译。

## 结果含义

| 状态 | 含义 |
|---|---|
| 未启用 | 配置为不解锁 |
| 等待下次启动 | 已启用，但本次启动还没有执行记录 |
| 已解锁 | 本次启动内核日志报告该卡 `gpu_unlock: unlocked` |
| 已被驱动占用而跳过 | 执行时该卡已绑定驱动；不会解绑或重试 |
| 本次跳过 | 缺少当前内核的模块包、模块加载失败，或地址不受支持；没有触碰硬件 |
| 解锁失败 | 该卡报告了失败，原因显示在后面；不会自动重试 |

`modprobe gpu_unlock` 成功并不代表解锁成功，每张卡的状态只来自本次调用新增的、带该卡 PCI 地址的内核日志。

如果页面提示“需要关机断电”，说明 gpu_unlock 报告固件未停止或卡已被初始化。此时本次启动已阻止加载 NVIDIA，也没有生成 CDI。请关机断电后再开机，不要只重启。

## 关闭、卸载与恢复

- **关闭解锁**：下次启动不再解锁，NVIDIA 按原方式在早期加载。
- **卸载**：撤销本插件的启动改动，删除本插件的文件和配置。
- 关闭或卸载都不会立即恢复已经生效的锁定状态。要恢复，需关机断电。
- WebUI 不可用时：删除 U 盘上的 `config/modprobe.d/gpu-unlock.conf`，然后重启。

工作原理和启动顺序见 [docs/boot-integration.md](docs/boot-integration.md)。

## 固件与许可

- 本仓库的代码（插件、构建脚本、测试）以 [GPL-2.0](LICENSE) 发布，与上游一致。
- 模块由上游 `GPL-2.0-only` 源码编译，固定在 commit `af28cbbfd3d922a659227ecfb7369adfd924cf03`；构建脚本和使用的 Unraid 内核补丁来源都在本仓库中。
- 固件含有 NVIDIA 的二进制文件，受 NVIDIA 驱动许可协议约束，上游也未取得再分发许可（见上游 `firmware/NOTICE.md`）。
  因此本仓库**不包含也不分发固件**；编译时从 NVIDIA 官方文件在你的服务器上生成，仅供自用，请勿再分发。

## 开发

```bash
bash tests/test-boot.sh
bash tests/test-status.sh
```

测试用替身命令模拟开机编排和日志解析，不涉及硬件。设计文档在 [docs/design/](docs/design/)。

发布新版本：

1. 修改 `gpu-unlock.plg` 中的 `version`，在 `<CHANGES>` 中写明改动。
2. 运行 `build/package.sh`，把 `build/out/gpu-unlock-ui-<版本>-x86_64-1.txz` 的 MD5 填入 `gpu-unlock.plg` 中的 `md5`。
3. 提交并推送 `main`，然后创建与版本号同名的 Release，上传这个 UI 包。

plg 的 `pluginURL` 指向 `main` 分支，所以推送之后、Release 发布之前的这段时间里，“检查更新”会发现新版本，但 UI 包还下载不到。请先建好 Release，或者把这两步紧挨着完成。
