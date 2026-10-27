#!/bin/bash
# Build the module and firmware packages of gpu-unlock and turing-unlock for the
# running Unraid kernel in a throwaway Arch Linux container, so the server itself
# gets no toolchain.
#
# usage (on the Unraid server, from a copy of this repository):
#   [PROJECTS="gpu-unlock turing-unlock"] \
#   [GPU_UNLOCK_COMMIT=…] [TURING_UNLOCK_COMMIT=…] \
#   [KERNEL_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/kernel/v6.x] \
#   [ARCH_MIRROR='https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch'] \
#   [https_proxy=http://host:port] build/unraid-container.sh WORK_DIR
#
# WORK_DIR/<project> may already hold an upstream clone with the pinned commit; it
# is then used without network access to GitHub.
#
# The kernel tree is kernel.org source plus Unraid's patches and config from
# /usr/src/linux-<release>; the module and firmware packages end up in WORK_DIR/out.
# The UI package comes from the GitHub release with the plugin.
set -euo pipefail

# The pinned upstream of each project.
UPSTREAM_gpu_unlock=https://github.com/Zagitta/gpu-unlock.git
COMMIT_gpu_unlock=${GPU_UNLOCK_COMMIT:-af28cbbfd3d922a659227ecfb7369adfd924cf03}
UPSTREAM_turing_unlock=https://github.com/nlzy/turing-unlock.git
COMMIT_turing_unlock=${TURING_UNLOCK_COMMIT:-417f333263ff169e8f449c931b70db9dfd7b8ef4}
IMAGE=archlinux:latest
# Config lines that only record which build tools were found. CONFIG_RUST is
# off, so the rustc probes (and whether "CONFIG_RUST is not set" is printed at
# all) do not change what gets built.
TOOL_PROBES='^CONFIG_(GCC_VERSION|CC_VERSION_TEXT|RUST_IS_AVAILABLE|RUSTC_[A-Z_]*)=|^# CONFIG_RUST is not set$'

inside() {
  local kver=${KERNEL%-Unraid} tar url=$KERNEL_MIRROR project upstream commit
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

  # Both upstreams pin the same NVIDIA inputs, checked by SHA-256 on every use: download once.
  export INPUTS=/work/home/.cache/gpu-unlock/inputs
  for project in $PROJECTS; do
    upstream=UPSTREAM_$(echo "$project" | tr - _)
    commit=COMMIT_$(echo "$project" | tr - _)
    [ -d "$project/.git" ] || git clone -q "${!upstream}" "$project"
    git -C "$project" cat-file -e "${!commit}^{commit}" 2> /dev/null || git -C "$project" fetch -q origin
    git -C "$project" checkout -q --detach "${!commit}"
    git -C "$project" clean -qfdx
    # No CONFIG_MODVERSIONS, so no Module.symvers: imports are checked against System.map instead.
    KBUILD_MODPOST_WARN=1 /repo/build/build.sh --src "/work/$project" --kdir /work/linux \
      --kernel "$KERNEL" --system-map /unraid/System.map --out /work/out
  done
}

if [ "${1:-}" = --inside ]; then
  inside
  exit
fi

[ $# -eq 1 ] || { sed -n '2,18p' "$0" >&2; exit 2; }
WORK=$1
PROJECTS=${PROJECTS:-gpu-unlock turing-unlock}
REPO=$(cd "$(dirname "$0")/.." && pwd)
KERNEL=$(uname -r)
mkdir -p "$WORK/pacman-cache"
exec nice -n 10 docker run --rm --cpus 16 \
  -e KERNEL="$KERNEL" -e PROJECTS="$PROJECTS" -e HOME=/work/home \
  -e GPU_UNLOCK_COMMIT="$COMMIT_gpu_unlock" -e TURING_UNLOCK_COMMIT="$COMMIT_turing_unlock" \
  -e KERNEL_MIRROR="${KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v6.x}" -e ARCH_MIRROR="${ARCH_MIRROR:-}" \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" -e no_proxy="${no_proxy:-}" \
  -v "$WORK:/work" -v "$WORK/pacman-cache:/var/cache/pacman/pkg" -v "$REPO:/repo:ro" -v "/usr/src/linux-$KERNEL:/unraid:ro" \
  "$IMAGE" /repo/build/unraid-container.sh --inside
