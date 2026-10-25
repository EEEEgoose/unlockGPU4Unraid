# GPU Unlock for Unraid

在 NVIDIA 驱动接管之前，对选定的 Ampere 显卡运行 [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)，
解锁 FP16/BF16 指令发射速率。NVIDIA 驱动、容器工具包和 CDI 仍由 NVIDIA Driver 插件负责。

## 支持范围

已实测的环境（详见 [docs/validation.md](docs/validation.md)）：

- Unraid 7.3.3，内核 `6.18.54-Unraid`，x86_64，NVIDIA 驱动 615.71.09
- 两张 RTX 3080 20 GB（`10de:2206`，改装显存），开机解锁成功，NVIDIA 正常接管四张卡

“上游支持该 PCI ID”不等于“该板卡已实测”。RTX 2080 Ti 等非 Ampere 显卡会显示为不支持，不能选择。
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

## 构建

```bash
# Linux x86_64，需要目标 Unraid 内核的已准备好的构建树
build/build.sh --src /path/to/gpu-unlock --kdir /path/to/unraid-6.18.54 --kernel 6.18.54-Unraid
# 任意平台
build/package.sh
```

产物位于 `build/out/`：

```text
gpu-unlock-ui-<插件版本>-x86_64-1.txz
gpu-unlock-kmod-1.0.0_6.18.54_Unraid-x86_64-1.txz
gpu-unlock-firmware-610.43.03-noarch-1.txz
```

固件由构建流程从上游固定的 NVIDIA 输入生成，不提交到本仓库。公开分发前，需要先按上游 `firmware/NOTICE.md` 确定分发方式。

## 安装（本地验证）

1. 把三个 `.txz` 复制到 U 盘的 `config/plugins/gpu-unlock/packages/`。
2. 把 `gpu-unlock.plg` 复制到 `config/plugins/`，然后在“插件 → 安装插件”中填入 `/boot/config/plugins/gpu-unlock.plg`。
3. 打开“设置 → GPU Unlock”，勾选要解锁的显卡，“下次启动解锁”选“是”，点击保存。
4. 冷启动。

安装后默认不启用。保存只改变下次启动的配置，不会在线解锁。

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

如果页面提示“需要关机断电”，说明 gpu_unlock 报告固件未停止或卡已被初始化。此时本次启动已阻止加载 NVIDIA、也没有生成 CDI。请关机断电后再开机，不要只重启。

## 关闭、卸载与恢复

- **关闭解锁**：下次启动不再解锁，NVIDIA 按原方式在早期加载。
- **卸载**：撤销本插件的启动改动，删除本插件的文件和配置。
- 关闭或卸载都不会立即恢复已经生效的锁定状态。要恢复，需关机断电。
- WebUI 不可用时：删除 U 盘上的 `config/modprobe.d/gpu-unlock.conf`，然后重启。

工作原理和启动顺序见 [docs/boot-integration.md](docs/boot-integration.md)。

## 测试

```bash
bash tests/test-boot.sh
bash tests/test-status.sh
```
