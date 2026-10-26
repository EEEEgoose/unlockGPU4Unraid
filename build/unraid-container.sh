#!/bin/bash
# Build the gpu-unlock module and firmware packages for the running Unraid kernel
# in a throwaway Arch Linux container, so the server itself gets no toolchain.
#
# usage (on the Unraid server, from a copy of this repository):
#   [KERNEL_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x] \
#   [ARCH_MIRROR='https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch'] \
#   [https_proxy=http://host:port] build/unraid-container.sh WORK_DIR [UPSTREAM_COMMIT]
#
# WORK_DIR/gpu-unlock may already hold an upstream clone with that commit; it is
# then used without network access to GitHub.
#
# The kernel tree is kernel.org source plus Unraid's patches and config from
# /usr/src/linux-<release>; the module and firmware packages end up in WORK_DIR/out.
# The UI package comes from the GitHub release with the plugin.
set -euo pipefail

UPSTREAM=https://github.com/Zagitta/gpu-unlock.git
DEFAULT_COMMIT=af28cbbfd3d922a659227ecfb7369adfd924cf03
IMAGE=archlinux:latest
# Config lines that only record which build tools were found. CONFIG_RUST is
# off, so the rustc probes (and whether "CONFIG_RUST is not set" is printed at
# all) do not change what gets built.
TOOL_PROBES='^CONFIG_(GCC_VERSION|CC_VERSION_TEXT|RUST_IS_AVAILABLE|RUSTC_[A-Z_]*)=|^# CONFIG_RUST is not set$'

inside() {
  local kver=${KERNEL%-Unraid} tar url=$KERNEL_MIRROR
  [ -z "$ARCH_MIRROR" ] || echo "Server = $ARCH_MIRROR" > /etc/pacman.d/mirrorlist
  pacman -Syu --noconfirm --needed base-devel bc cpio git kmod libelf python xz > /dev/null
  echo "toolchain: $(gcc --version | head -n 1); $(ld --version | head -n 1); $(python3 --version)"

  cd /work
  tar=linux-$kver.tar.xz
  if [ ! -f "$tar" ]; then
    curl -fL --retry 3 -o "$tar.part" "$url/$tar"
    mv "$tar.part" "$tar"
  fi
  curl -fsSL "$url/sha256sums.asc" | grep " $tar\$" | sha256sum -c -

  rm -rf linux
  mkdir linux
  tar -xf "$tar" -C linux --strip-components=1
  cp -R /unraid/drivers/. linux/drivers/
  for p in /unraid/*.patch; do
    echo "patch: $(basename "$p")"
    patch -d linux -p1 --forward --no-backup-if-mismatch < "$p"
  done
  cp /unraid/config linux/.config
  make -C linux olddefconfig
  if ! diff <(grep -E '^(# )?CONFIG_' /unraid/config | grep -Ev "$TOOL_PROBES") \
            <(grep -E '^(# )?CONFIG_' linux/.config | grep -Ev "$TOOL_PROBES"); then
    echo ".config differs from Unraid's beyond the build tool probes" >&2
    exit 1
  fi
  echo "config: same as Unraid's; tool probes: $(grep -E "$TOOL_PROBES" linux/.config | tr '\n' ' ')"
  make -C linux -j"$(nproc)" modules_prepare

  [ -d gpu-unlock/.git ] || git clone -q "$UPSTREAM" gpu-unlock
  git -C gpu-unlock cat-file -e "$COMMIT^{commit}" 2> /dev/null || git -C gpu-unlock fetch -q origin
  git -C gpu-unlock checkout -q --detach "$COMMIT"
  git -C gpu-unlock clean -qfdx
  # No CONFIG_MODVERSIONS, so no Module.symvers: imports are checked against System.map instead.
  KBUILD_MODPOST_WARN=1 /repo/build/build.sh --src /work/gpu-unlock --kdir /work/linux \
    --kernel "$KERNEL" --system-map /unraid/System.map --out /work/out
}

if [ "${1:-}" = --inside ]; then
  inside
  exit
fi

[ $# -ge 1 ] || { sed -n '2,15p' "$0" >&2; exit 2; }
WORK=$1
COMMIT=${2:-$DEFAULT_COMMIT}
REPO=$(cd "$(dirname "$0")/.." && pwd)
KERNEL=$(uname -r)
mkdir -p "$WORK/pacman-cache"
exec nice -n 10 docker run --rm --cpus 16 \
  -e KERNEL="$KERNEL" -e COMMIT="$COMMIT" -e HOME=/work/home \
  -e KERNEL_MIRROR="${KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v6.x}" -e ARCH_MIRROR="${ARCH_MIRROR:-}" \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" -e no_proxy="${no_proxy:-}" \
  -v "$WORK:/work" -v "$WORK/pacman-cache:/var/cache/pacman/pkg" -v "$REPO:/repo:ro" -v "/usr/src/linux-$KERNEL:/unraid:ro" \
  "$IMAGE" /repo/build/unraid-container.sh --inside
