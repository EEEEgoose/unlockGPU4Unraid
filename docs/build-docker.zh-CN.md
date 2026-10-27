# 用 Docker 编译模块和固件

[English](build-docker.md) | 简体中文

插件用到的包全部放在 U 盘的 `config/plugins/gpu-unlock/packages/` 下。gpu-unlock（Ampere）和 turing-unlock（Turing）各有一个模块包和一个固件包，需要按本文编译；UI 包不用编译：

| 包 | 内容 | 什么时候需要重新编译 |
|---|---|---|
| `gpu-unlock-kmod-…_<内核>-x86_64-1.txz` | 内核模块 `gpu_unlock.ko` | 每次 Unraid 升级内核后 |
| `gpu-unlock-firmware-610.43.03-noarch-1.txz` | 解锁时加载到显卡上的 5 个固件文件 | 上游 gpu-unlock 更新固件版本时 |
| `turing-unlock-kmod-…_<内核>-x86_64-1.txz` | 内核模块 `turing_unlock.ko` | 每次 Unraid 升级内核后 |
| `turing-unlock-firmware-610.43.03-noarch-1.txz` | Turing 解锁用的 6 个固件文件 | 上游 turing-unlock 更新固件版本时 |
| `gpu-unlock-ui-<插件版本>-x86_64-1.txz` | 控制脚本和设置页面 | 不用编译：安装或更新插件时自动从 GitHub Releases 下载，并校验 MD5 |

固件含有 NVIDIA 的二进制文件，本仓库不分发固件，模块包和固件包都由你在自己的服务器上编译。编译过程中，固件由 NVIDIA 官方文件生成，生成后只供你自己使用，不要再分发。

整个编译都在一个临时的 Arch Linux 容器里完成，编译结束后容器自动删除，Unraid 系统本身不会被装上任何编译工具。

## 准备

- Unraid 7.3 及以上，已启用 Docker，已安装 NVIDIA Driver 插件。
- 在 SSD 池上留出约 10 GB 空间作为工作目录，下文以 `/mnt/cache/build/gpu-unlock` 为例。不要放在阵列盘上。
- 能访问下面这些地址，也可以改用镜像或代理（见第 2 步）：
  - `cdn.kernel.org`：内核源码
  - Arch Linux 软件源：编译工具
  - `github.com`：上游 gpu-unlock 和 turing-unlock 源码
  - `download.nvidia.com`、`archive.cachyos.org`：生成固件用的 NVIDIA 原始文件，下载后会校验 SHA-256
- 编译需要在**正在运行目标内核**的系统上进行。脚本会读取 `/usr/src/linux-$(uname -r)` 中 Unraid 提供的内核配置、补丁和 `System.map`。

以下命令都在 Unraid 终端里以 root 执行。

## 1. 下载本仓库

```bash
mkdir -p /mnt/cache/build/gpu-unlock
cd /mnt/cache/build/gpu-unlock
rm -rf repo unlockGPU4Unraid-main
curl -fL https://github.com/EEEEgoose/unlockGPU4Unraid/archive/refs/heads/main.tar.gz | tar -xz
mv unlockGPU4Unraid-main repo
```

第二行会删掉上次下载的旧源码，保证后面用的 `repo/` 一定是这次下载的新版本。工作目录里的其他内容会保留，再次编译时可以直接复用：编译产物 `out/`、内核源码包、`pacman-cache/` 和上游 `gpu-unlock/`。

## 2. 编译

```bash
cd /mnt/cache/build/gpu-unlock
repo/build/unraid-container.sh /mnt/cache/build/gpu-unlock
```

如果下载很慢或连不上，可以指定镜像或代理，例如：

```bash
KERNEL_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x \
ARCH_MIRROR='https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
https_proxy=http://代理地址:端口 http_proxy=http://代理地址:端口 \
no_proxy=localhost,127.0.0.1,mirrors.tuna.tsinghua.edu.cn \
repo/build/unraid-container.sh /mnt/cache/build/gpu-unlock
```

脚本按顺序完成以下工作，任何一步检查不通过都会停止，不会输出有问题的包：

1. 安装编译工具：gcc、binutils、Python 3.14 等。
2. 下载内核源码并校验 sha256，打上 `/usr/src` 中的 Unraid 补丁，然后用 Unraid 的配置执行 `olddefconfig`。生成的 `.config` 必须与 Unraid 原配置一致，只允许编译器版本和 Rust 探测项不同。
3. 依次下载上游 gpu-unlock 和 turing-unlock（各自固定 commit），编译模块，生成固件，运行上游测试（turing-unlock 没有测试，这一步会跳过）。两个项目使用同一份 NVIDIA 原始文件，只下载一次。
4. 检查模块的 vermagic 与当前内核一致，并确认模块用到的每个符号都能在 `System.map` 中找到。
5. 打出两个项目的模块包和固件包，共 4 个。

只需要其中一个时，可以在命令前加 `PROJECTS=gpu-unlock` 或 `PROJECTS=turing-unlock`。

第一次编译约需 10–20 分钟，主要取决于下载速度。容器最多使用 16 个 CPU 核心，并以较低优先级运行。

## 3. 安装

```bash
cd /mnt/cache/build/gpu-unlock
ls out/
mkdir -p /boot/config/plugins/gpu-unlock/packages
cp out/*.txz /boot/config/plugins/gpu-unlock/packages/
plugin install https://raw.githubusercontent.com/EEEEgoose/unlockGPU4Unraid/main/gpu-unlock.plg
```

也可以在网页的 **插件 → 安装插件** 中粘贴上面的 plg 地址。安装时，插件会从 GitHub Releases 下载 UI 包并保存到同一目录，之后开机不再需要联网。
如果服务器访问不了 GitHub，可以先在 Unraid 的出站代理（Outgoing Proxy）设置中配置代理，或者在终端里加上 `https_proxy=…` 再执行 `plugin install`。

之后插件的更新会出现在 **插件** 页面的“检查更新”中，可以直接在那里更新。插件更新不需要重新编译模块包和固件包。

安装后默认不启用。打开 **设置 → 实用工具 → GPU Unlock**，勾选要解锁的显卡，“下次启动解锁”选“是”并保存，然后冷启动。

## Unraid 升级内核之后

新内核启动后，插件找不到对应的模块包，本次启动会跳过解锁，NVIDIA 照常加载。在新内核下重新执行第 1–3 步即可。固件包可以沿用，只要文件名不变，覆盖也没有关系。

## 清理

```bash
rm -rf /mnt/cache/build/gpu-unlock
docker rmi archlinux:latest
```

U 盘上 `config/plugins/gpu-unlock/packages/` 里的包要保留，每次开机都要从这里安装。
