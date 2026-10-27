#!/bin/bash
# Boot ordering and failure branches of gpu-unlock-control, followed by the
# nvidia-driver.plg stage that rc.local runs next.
. "$(dirname "$0")/harness.sh"

TARGETS=0000:cc:00.0,0000:cd:00.0
TURING=0000:c5:00.0,0000:c8:00.0

packages() {
  mkdir -p "$GPU_UNLOCK_PLUGIN_DIR/packages"
  touch "$GPU_UNLOCK_PLUGIN_DIR/packages/gpu-unlock-kmod-1.0.0_6.18.54_Unraid-x86_64-1.txz" \
        "$GPU_UNLOCK_PLUGIN_DIR/packages/gpu-unlock-firmware-610.43.03-noarch-1.txz"
}

turing_packages() {
  mkdir -p "$GPU_UNLOCK_PLUGIN_DIR/packages"
  touch "$GPU_UNLOCK_PLUGIN_DIR/packages/turing-unlock-kmod-2.0.0_6.18.54_Unraid-x86_64-1.txz" \
        "$GPU_UNLOCK_PLUGIN_DIR/packages/turing-unlock-firmware-610.43.03-noarch-1.txz"
}

# inspect: every NVIDIA GPU is listed, only supported cards are unlockable, none preselected.
setup
add_gpu 0000:d5:00.0 2000 1a03
add_gpu 0000:cc:00.1 1aef 10de 040300
check "inspect: NVIDIA GPUs only" "0000:c5:00.0 0000:c8:00.0 0000:cc:00.0 0000:cd:00.0" \
  "$("$CONTROL" inspect | awk -F '\t' '$1 == "gpu" { print $2 }' | sort | tr '\n' ' ' | sed 's/ $//')"
check "inspect: unlock module per card" "0000:c5:00.0=turing_unlock 0000:c8:00.0=turing_unlock 0000:cc:00.0=gpu_unlock 0000:cd:00.0=gpu_unlock" \
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
check "prepare-boot refuses a 2080 Ti without turing packages" no "$([ -f "$W/boot/modprobe.d/gpu-unlock.conf" ] && echo yes || echo no)"
turing_packages
"$CONTROL" prepare-boot > /dev/null 2>&1
check "prepare-boot accepts a 2080 Ti with turing packages" yes "$([ -f "$W/boot/modprobe.d/gpu-unlock.conf" ] && echo yes || echo no)"
rm -f "$W/boot/modprobe.d/gpu-unlock.conf"
add_gpu 0000:d5:00.0 2000 1a03
configure yes 0000:d5:00.0
"$CONTROL" prepare-boot > /dev/null 2>&1
check "prepare-boot refuses a card no module supports" no "$([ -f "$W/boot/modprobe.d/gpu-unlock.conf" ] && echo yes || echo no)"
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
check "disable keeps the selection" "enabled=\"no\" targets=\"$(entry 0000:cc:00.0),$(entry 0000:cd:00.0)\"" "$(tr '\n' ' ' < "$GPU_UNLOCK_PLUGIN_DIR/settings.cfg" | sed 's/ $//')"
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
  check "$branch: order" "unlock gpu_unlock targets=$TARGETS nvidia cdi" "$(events)"
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
    check "$branch/$fixture: no nvidia, no cdi" "unlock gpu_unlock targets=$TARGETS notify" "$(events)"
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
check "alias modules: order" "unlock gpu_unlock targets=$TARGETS nvidia nvidia_drm cdi" "$(events)"
teardown

# The power-off block also refuses nvidia_drm, which would pull nvidia in as a dependency.
setup
configure yes $TARGETS
early_boot module-present
STUB_ALIAS_MODULES="nvidia nvidia_drm" STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-poweroff.txt "$CONTROL" boot
modprobe nvidia_drm 2> /dev/null
nvidia_driver_stage > /dev/null 2>&1
check "power off: nvidia_drm refused too" "unlock gpu_unlock targets=$TARGETS notify" "$(events)"
teardown

# Ampere and Turing cards together: one load per module, both before NVIDIA.
setup
configure yes $TARGETS,$TURING
early_boot module-present
"$CONTROL" boot
nvidia_driver_stage
check "both modules: order" "unlock gpu_unlock targets=$TARGETS unlock turing_unlock targets=$TURING nvidia cdi" "$(events)"
check "both modules: all unlocked" "unlocked unlocked unlocked unlocked" \
  "$(state_of 0000:cc:00.0) $(state_of 0000:cd:00.0) $(state_of 0000:c5:00.0) $(state_of 0000:c8:00.0)"
check "both modules: unlocker recorded" "gpu_unlock turing_unlock" "$(unlocker_of 0000:cc:00.0) $(unlocker_of 0000:c8:00.0)"
teardown

# A Turing fault that needs a power off blocks NVIDIA for every card.
setup
configure yes $TARGETS,$TURING
early_boot module-present
STUB_TURING_FIXTURE=$FIXTURES/kmsg-turing-poweroff.txt "$CONTROL" boot
nvidia_driver_stage > /dev/null 2>&1
check "turing power off: no nvidia, no cdi" "unlock gpu_unlock targets=$TARGETS unlock turing_unlock targets=$TURING notify" "$(events)"
check "turing power off: c5 failed" failed "$(state_of 0000:c5:00.0)"
check "turing power off: reason" "turing_unlock: firmware did not stop; retaining DMA resources until power off" "$(reason_of 0000:c5:00.0)"
check "turing power off: ampere cards still unlocked" "unlocked unlocked" "$(state_of 0000:cc:00.0) $(state_of 0000:cd:00.0)"
teardown

# Only the Ampere module installed: Turing cards skipped, Ampere unlocked, NVIDIA loads.
setup
configure yes $TARGETS,$TURING
early_boot module-present
STUB_HAVE_TURING_UNLOCK=no "$CONTROL" boot
nvidia_driver_stage
check "no turing package: order" "unlock gpu_unlock targets=$TARGETS nvidia cdi" "$(events)"
check "no turing package: reason" "no turing_unlock package for kernel 6.18.54-Unraid" "$(reason_of 0000:c5:00.0)"
check "no turing package: ampere unlocked" unlocked "$(state_of 0000:cd:00.0)"
teardown

# The saved card's UUID is checked once NVIDIA reports it.
setup
configure yes $TARGETS
early_boot module-present
"$CONTROL" boot
check "uuid: recorded" GPU-test-0000:cc:00.0 "$("$CONTROL" status | jq -r '.targets[] | select(.pci == "0000:cc:00.0") | .uuid')"
check "uuid: selection kept" "$(entry 0000:cc:00.0),$(entry 0000:cd:00.0)" "$(saved_targets)"
check "uuid: no notice" "" "$(grep -c notify "$W/events" | grep -v '^0$')"
teardown

# A card of another kind now sits at a saved address: not unlocked, notified, dropped.
setup
configure yes $TARGETS
early_boot module-present
add_gpu 0000:cc:00.0 1e07
"$CONTROL" boot
check "changed card: only the other card unlocked" "unlock gpu_unlock targets=0000:cd:00.0 nvidia notify" "$(events)"
check "changed card: skipped" skipped "$(state_of 0000:cc:00.0)"
check "changed card: reason" "the card at 0000:cc:00.0 changed (saved 10de:2206@10de:146d, found 10de:1e07@10de:12fa); select the card again" "$(reason_of 0000:cc:00.0)"
check "changed card: dropped from the selection" "$(entry 0000:cd:00.0)" "$(saved_targets)"
check "changed card: still enabled" yes "$(grep -q 'enabled="yes"' "$GPU_UNLOCK_PLUGIN_DIR/settings.cfg" && echo yes)"
teardown

# Identical cards swapped: the card unlocked at the address is not the selected one.
setup
packages
configure yes 0000:cc:00.0
"$CONTROL" prepare-boot > /dev/null
early_boot module-present
sed -i.bak 's/GPU-test-0000:cc:00.0$/GPU-test-moved/' "$W/uuids"
"$CONTROL" boot
check "swapped card: unlocked then reported" "unlock gpu_unlock targets=0000:cc:00.0 nvidia notify" "$(events)"
check "swapped card: wrong card" wrong_card "$(state_of 0000:cc:00.0)"
check "swapped card: reason" "the card at 0000:cc:00.0 is GPU-test-moved, not the selected GPU-test-0000:cc:00.0; select the card again" "$(reason_of 0000:cc:00.0)"
check "swapped card: last card dropped disables" 'enabled="no" targets=""' "$(tr '\n' ' ' < "$GPU_UNLOCK_PLUGIN_DIR/settings.cfg" | sed 's/ $//')"
check "swapped card: boot rule removed" no "$([ -f "$W/boot/modprobe.d/gpu-unlock.conf" ] && echo yes || echo no)"
teardown

# An address saved by an older version: not unlocked, dropped, the UUID cards still unlocked.
setup
configure yes legacy:0000:cc:00.0,0000:cd:00.0
early_boot module-present
"$CONTROL" boot
check "legacy entry: only the full entry unlocked" "unlock gpu_unlock targets=0000:cd:00.0 nvidia notify" "$(events)"
check "legacy entry: reason" "saved by an older version without the card's UUID; select the card again" "$(reason_of 0000:cc:00.0)"
check "legacy entry: dropped" "$(entry 0000:cd:00.0)" "$(saved_targets)"
teardown

# No UUID from NVIDIA (its package not installed yet): noted, selection kept.
setup
configure yes $TARGETS
early_boot needs-install
"$CONTROL" boot
check "unverified: unlocked" unlocked "$(state_of 0000:cc:00.0)"
check "unverified: note" "UUID not verified: NVIDIA does not report the card at 0000:cc:00.0" "$("$CONTROL" status | jq -r '.targets[] | select(.pci == "0000:cc:00.0") | .note')"
check "unverified: selection kept" "$(entry 0000:cc:00.0),$(entry 0000:cd:00.0)" "$(saved_targets)"
teardown

# The page marks a card selected by its UUID, wherever it is now.
setup
configure no 0000:cd:00.0
mkdir -p "$W/sys/module/nvidia"
sed -i.bak 's/GPU-test-0000:cd:00.0$/GPU-test-elsewhere/; s/GPU-test-0000:cc:00.0$/GPU-test-0000:cd:00.0/' "$W/uuids"
check "inspect: selection follows the UUID" 0000:cc:00.0 "$("$CONTROL" inspect | awk -F '\t' '$1 == "gpu" && $6 == "yes" { print $2 }')"
check "inspect: entry to save" "GPU-test-0000:cd:00.0@0000:cc:00.0@10de:2206@10de:146d" "$("$CONTROL" inspect | awk -F '\t' '$2 == "0000:cc:00.0" { print $9 }')"
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
check "module load failure: nvidia still loads" "unlock gpu_unlock targets=$TARGETS nvidia cdi" "$(events)"
check "module load failure: skipped" "gpu_unlock failed to load (1)" "$(reason_of 0000:cd:00.0)"
teardown

# Ordinary unlock failure on one card: logged per card, NVIDIA loads for all.
setup
configure yes $TARGETS
early_boot module-present
STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-mixed.txt "$CONTROL" boot
nvidia_driver_stage
check "one card failed: nvidia loads" "unlock gpu_unlock targets=$TARGETS nvidia cdi" "$(events)"
teardown

# A bound target is skipped: no unbind, no unlock attempt on it.
setup
configure yes $TARGETS
early_boot module-present
bind_gpu 0000:cc:00.0 nvidia
STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-ok.txt "$CONTROL" boot
check "bound: only the free card is unlocked" "unlock gpu_unlock targets=0000:cd:00.0 nvidia" "$(events)"
check "bound: state" skipped_bound "$(state_of 0000:cc:00.0)"
check "bound: driver kept" nvidia "$(basename "$(readlink "$W/sys/pci/0000:cc:00.0/driver")")"
teardown

# Running boot again in the same boot (plugin update, manual install) does nothing.
setup
configure yes $TARGETS
early_boot module-present
"$CONTROL" boot
"$CONTROL" boot
check "second run: one unlock only" "unlock gpu_unlock targets=$TARGETS nvidia" "$(events)"
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
