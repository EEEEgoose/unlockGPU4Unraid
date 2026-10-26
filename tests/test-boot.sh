#!/bin/bash
# Boot ordering and failure branches of gpu-unlock-control, followed by the
# nvidia-driver.plg stage that rc.local runs next.
. "$(dirname "$0")/harness.sh"

TARGETS=0000:cc:00.0,0000:cd:00.0

packages() {
  mkdir -p "$GPU_UNLOCK_PLUGIN_DIR/packages"
  touch "$GPU_UNLOCK_PLUGIN_DIR/packages/gpu-unlock-kmod-1.0.0_6.18.54_Unraid-x86_64-1.txz" \
        "$GPU_UNLOCK_PLUGIN_DIR/packages/gpu-unlock-firmware-610.43.03-noarch-1.txz"
}

# inspect: every NVIDIA GPU is listed, only supported cards are unlockable, none preselected.
setup
add_gpu 0000:d5:00.0 2000 1a03
add_gpu 0000:cc:00.1 1aef 10de 040300
check "inspect: NVIDIA GPUs only" "0000:c5:00.0 0000:c8:00.0 0000:cc:00.0 0000:cd:00.0" \
  "$("$CONTROL" inspect | awk -F '\t' '$1 == "gpu" { print $2 }' | sort | tr '\n' ' ' | sed 's/ $//')"
check "inspect: unlockable" "0000:c5:00.0=no 0000:c8:00.0=no 0000:cc:00.0=yes 0000:cd:00.0=yes" \
  "$("$CONTROL" inspect | awk -F '\t' '$1 == "gpu" { print $2 "=" $4 }' | sort | tr '\n' ' ' | sed 's/ $//')"
check "inspect: model without address and class" "NVIDIA Corporation GA102 [GeForce RTX 3080] (rev a1)" \
  "$("$CONTROL" inspect | awk -F '\t' '$2 == "0000:cc:00.0" { print $7 }')"
bind_gpu 0000:c5:00.0 nvidia
mkdir -p "$W/sys/module/nvidia" && echo 615.71.09 > "$W/sys/module/nvidia/version"
check "inspect: driver with version" "nvidia 615.71.09" "$("$CONTROL" inspect | awk -F '\t' '$2 == "0000:c5:00.0" { print $5 }')"
check "inspect: unbound card" none "$("$CONTROL" inspect | awk -F '\t' '$2 == "0000:cc:00.0" { print $5 }')"
check "inspect: nothing selected after install" "" "$("$CONTROL" inspect | awk -F '\t' '$1 == "gpu" && $6 == "yes"')"
configure no 0000:cd:00.0
check "inspect: user selection" 0000:cd:00.0 "$("$CONTROL" inspect | awk -F '\t' '$1 == "gpu" && $6 == "yes" { print $2 }')"
teardown

# prepare-boot: the deferral is written only with packages on the flash and supported targets.
setup
configure yes $TARGETS
"$CONTROL" prepare-boot > /dev/null 2>&1
check "prepare-boot without packages refuses" no "$([ -f "$W/boot/modprobe.d/gpu-unlock.conf" ] && echo yes || echo no)"
packages
configure yes 0000:c5:00.0
"$CONTROL" prepare-boot > /dev/null 2>&1
check "prepare-boot refuses a 2080 Ti" no "$([ -f "$W/boot/modprobe.d/gpu-unlock.conf" ] && echo yes || echo no)"
configure yes $TARGETS
"$CONTROL" prepare-boot > /dev/null
check "prepare-boot defers every nvidia module" \
  "blacklist nvidia blacklist nvidia_uvm blacklist nvidia_modeset blacklist nvidia_drm blacklist nvidia_peermem" \
  "$(grep -v '^#' "$W/boot/modprobe.d/gpu-unlock.conf" | tr '\n' ' ' | sed 's/ $//')"
check "prepare-boot touches no hardware" "" "$(events)"
# The flash refuses the rule: no success message, non-zero exit, no partial file.
if [ "$(id -u)" != 0 ]; then
  rm -f "$W/boot/modprobe.d/gpu-unlock.conf"
  chmod 555 "$W/boot/modprobe.d"
  out=$("$CONTROL" prepare-boot 2> /dev/null)
  check "prepare-boot write failure exits non-zero" 1 "$?"
  check "prepare-boot write failure reports no success" "" "$out"
  check "prepare-boot write failure leaves no rule" no "$(ls "$W/boot/modprobe.d" | grep -q gpu-unlock && echo yes || echo no)"
  chmod 755 "$W/boot/modprobe.d"
  "$CONTROL" prepare-boot > /dev/null
fi
"$CONTROL" disable > /dev/null
check "disable removes the deferral" no "$([ -f "$W/boot/modprobe.d/gpu-unlock.conf" ] && echo yes || echo no)"
check "disable keeps the selection" 'enabled="no" targets="0000:cc:00.0,0000:cd:00.0"' "$(tr '\n' ' ' < "$GPU_UNLOCK_PLUGIN_DIR/settings.cfg" | sed 's/ $//')"
teardown

for branch in module-present needs-install; do
  # Success: unlock, then nvidia, then CDI.
  setup
  packages
  configure yes $TARGETS
  "$CONTROL" prepare-boot > /dev/null
  early_boot $branch
  "$CONTROL" boot
  nvidia_driver_stage
  check "$branch: order" "unlock targets=$TARGETS nvidia cdi" "$(events)"
  check "$branch: both unlocked" "unlocked unlocked" "$(state_of 0000:cc:00.0) $(state_of 0000:cd:00.0)"
  teardown

  # Fault that needs a power off: boot returns 0, rc.local goes on, yet no nvidia and no CDI.
  for fixture in kmsg-poweroff.txt kmsg-wpr2.txt; do
    setup
    packages
    configure yes $TARGETS
    "$CONTROL" prepare-boot > /dev/null
    early_boot $branch
    STUB_UNLOCK_FIXTURE=$FIXTURES/$fixture "$CONTROL" boot
    check "$branch/$fixture: boot exit status" 0 "$?"
    nvidia_driver_stage > /dev/null 2>&1
    check "$branch/$fixture: no nvidia, no cdi" "unlock targets=$TARGETS notify" "$(events)"
    check "$branch/$fixture: block rule present" yes "$(grep -qs '^install nvidia /bin/false' "$W/etc/modprobe.d/gpu-unlock-block.conf" && echo yes || echo no)"
    teardown
  done
done

# After the unlock, the NVIDIA modules udev would have loaded are loaded, never nouveau or nvidiafb.
setup
configure yes $TARGETS
early_boot module-present
STUB_ALIAS_MODULES="nouveau nvidiafb nvidia nvidia_drm" "$CONTROL" boot
nvidia_driver_stage
check "alias modules: order" "unlock targets=$TARGETS nvidia nvidia_drm cdi" "$(events)"
teardown

# The power-off block also refuses nvidia_drm, which would pull nvidia in as a dependency.
setup
configure yes $TARGETS
early_boot module-present
STUB_ALIAS_MODULES="nvidia nvidia_drm" STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-poweroff.txt "$CONTROL" boot
modprobe nvidia_drm 2> /dev/null
nvidia_driver_stage > /dev/null 2>&1
check "power off: nvidia_drm refused too" "unlock targets=$TARGETS notify" "$(events)"
teardown

# Missing kmod for this kernel: no unlock, normal NVIDIA path kept.
setup
configure yes $TARGETS
early_boot module-present
STUB_HAVE_GPU_UNLOCK=no "$CONTROL" boot
nvidia_driver_stage
check "missing package: nvidia still loads" "nvidia cdi" "$(events)"
check "missing package: skipped" skipped "$(state_of 0000:cc:00.0)"
check "missing package: reason" "no gpu_unlock package for kernel 6.18.54-Unraid" "$(reason_of 0000:cc:00.0)"
teardown

# gpu_unlock fails to load (e.g. unresolved symbol): cards untouched, nvidia loads.
setup
configure yes $TARGETS
early_boot module-present
STUB_UNLOCK_RC=1 "$CONTROL" boot
nvidia_driver_stage
check "module load failure: nvidia still loads" "unlock targets=$TARGETS nvidia cdi" "$(events)"
check "module load failure: skipped" "gpu_unlock failed to load (1)" "$(reason_of 0000:cd:00.0)"
teardown

# Ordinary unlock failure on one card: logged per card, NVIDIA loads for all.
setup
configure yes $TARGETS
early_boot module-present
STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-mixed.txt "$CONTROL" boot
nvidia_driver_stage
check "one card failed: nvidia loads" "unlock targets=$TARGETS nvidia cdi" "$(events)"
teardown

# A bound target is skipped: no unbind, no unlock attempt on it.
setup
configure yes $TARGETS
early_boot module-present
bind_gpu 0000:cc:00.0 nvidia
STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-ok.txt "$CONTROL" boot
check "bound: only the free card is unlocked" "unlock targets=0000:cd:00.0 nvidia" "$(events)"
check "bound: state" skipped_bound "$(state_of 0000:cc:00.0)"
check "bound: driver kept" nvidia "$(basename "$(readlink "$W/sys/pci/0000:cc:00.0/driver")")"
teardown

# Running boot again in the same boot (plugin update, manual install) does nothing.
setup
configure yes $TARGETS
early_boot module-present
"$CONTROL" boot
"$CONTROL" boot
check "second run: one unlock only" "unlock targets=$TARGETS nvidia" "$(events)"
teardown

# Disabled: no unlock; a deferral left from the flash is undone by loading nvidia.
setup
configure no $TARGETS
echo "blacklist nvidia" > "$W/boot/modprobe.d/gpu-unlock.conf"
early_boot module-present
"$CONTROL" boot
nvidia_driver_stage
check "disabled: nvidia loads without unlock" "nvidia cdi" "$(events)"
teardown

finish
