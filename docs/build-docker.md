# Building the module and firmware with Docker

English | [简体中文](build-docker.zh-CN.md)

The plugin uses three packages in `config/plugins/gpu-unlock/packages/` on the flash drive. You build the module and firmware packages as described here; the UI package needs no build:

| Package | Contents | Rebuild when |
|---|---|---|
| `gpu-unlock-kmod-…_<kernel>-x86_64-1.txz` | The `gpu_unlock.ko` kernel module | Unraid ships a new kernel |
| `gpu-unlock-firmware-610.43.03-noarch-1.txz` | The five firmware files the unlock loads onto the card | Upstream gpu-unlock moves to another firmware version |
| `gpu-unlock-ui-<plugin version>-x86_64-1.txz` | Control script and settings page | Never: installing or updating the plugin downloads it from GitHub Releases and checks its MD5 |

The firmware contains NVIDIA binaries, so this repository does not distribute it: you build the module and firmware packages on your own server. The build generates the firmware from NVIDIA's own files, for your own use; do not redistribute it.

Everything runs in a throwaway Arch Linux container that is removed when the build ends. No build tools are installed on Unraid itself.

## Before you start

- Unraid 7.3 or later, with Docker enabled and the NVIDIA Driver plugin installed.
- About 10 GB free on an SSD pool for the work directory, `/mnt/cache/build/gpu-unlock` below. Not on the array.
- Access to these hosts, or mirrors and a proxy (step 2):
  - `cdn.kernel.org`: kernel source
  - Arch Linux repositories: build tools
  - `github.com`: upstream gpu-unlock source
  - `download.nvidia.com`, `archive.cachyos.org`: the NVIDIA files the firmware is generated from, checked against their SHA-256
- Build on the system **running the target kernel**. The script reads Unraid's kernel config, patches and `System.map` from `/usr/src/linux-$(uname -r)`.

Run the commands below as root in the Unraid terminal.

## 1. Download this repository

```bash
mkdir -p /mnt/cache/build/gpu-unlock
cd /mnt/cache/build/gpu-unlock
rm -rf repo unlockGPU4Unraid-main
curl -fL https://github.com/EEEEgoose/unlockGPU4Unraid/archive/refs/heads/main.tar.gz | tar -xz
mv unlockGPU4Unraid-main repo
```

The second line removes the source downloaded last time, so the `repo/` used below is always this download. The rest
of the work directory stays and is reused by the next build: `out/`, the kernel tarball, `pacman-cache/` and the
upstream `gpu-unlock/` clone.

## 2. Build

```bash
cd /mnt/cache/build/gpu-unlock
repo/build/unraid-container.sh /mnt/cache/build/gpu-unlock
```

If downloads are slow or blocked, point the build at mirrors or a proxy, for example:

```bash
KERNEL_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x \
ARCH_MIRROR='https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch' \
https_proxy=http://proxy-host:port http_proxy=http://proxy-host:port \
no_proxy=localhost,127.0.0.1,mirrors.tuna.tsinghua.edu.cn \
repo/build/unraid-container.sh /mnt/cache/build/gpu-unlock
```

The script runs these steps in order and stops at the first failed check, so it never outputs a bad package:

1. Installs the build tools: gcc, binutils, Python 3.14 and so on.
2. Downloads the kernel source and checks its sha256, applies Unraid's patches from `/usr/src`, and runs `olddefconfig` with Unraid's config. The resulting `.config` must match Unraid's except for the compiler version and the Rust probes.
3. Downloads upstream gpu-unlock at a pinned commit, builds the module, generates the firmware and runs the upstream tests.
4. Checks that the module's vermagic matches the running kernel and that every symbol it imports is in `System.map`.
5. Writes the module and firmware packages.

The first build takes about 10–20 minutes, mostly downloads. The container uses at most 16 CPU cores at low priority.

## 3. Install

```bash
cd /mnt/cache/build/gpu-unlock
ls out/
mkdir -p /boot/config/plugins/gpu-unlock/packages
cp out/*.txz /boot/config/plugins/gpu-unlock/packages/
plugin install https://raw.githubusercontent.com/EEEEgoose/unlockGPU4Unraid/main/gpu-unlock.plg
```

You can also paste the plg URL into **Plugins → Install Plugin** in the web UI. The install downloads the UI package
from GitHub Releases into the same directory, so later boots need no network. If the server cannot reach GitHub, configure
Unraid's outgoing proxy first, or prefix `plugin install` with `https_proxy=…` in the terminal.

Plugin updates then show up under "Check for updates" on the **Plugins** page and install from there. They do not
require rebuilding the module and firmware packages.

The plugin starts disabled. Open **Settings → Utilities → GPU Unlock**, tick the cards to unlock, set "unlock at next boot" to yes, save, and power cycle the server.

## After an Unraid kernel upgrade

On the new kernel the plugin finds no matching module package, skips the unlock for that boot and lets NVIDIA load as usual. Repeat steps 1–3 on the new kernel. The firmware package can stay; overwriting it with the same file name does no harm.

## Cleaning up

```bash
rm -rf /mnt/cache/build/gpu-unlock
docker rmi archlinux:latest
```

Keep the packages in `config/plugins/gpu-unlock/packages/` on the flash drive: they are installed from there on every boot.
