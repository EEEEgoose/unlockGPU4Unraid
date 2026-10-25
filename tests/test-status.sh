#!/bin/bash
# Per-card results parsed from the kernel log lines added by one gpu_unlock load.
. "$(dirname "$0")/harness.sh"

# modprobe returns 0 although one card failed: each card keeps its own result.
setup
configure yes 0000:cc:00.0,0000:cd:00.0
early_boot module-present
STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-mixed.txt "$CONTROL" boot
check "mixed: cc unlocked" unlocked "$(state_of 0000:cc:00.0)"
check "mixed: cd failed, earlier 'unlocked' line ignored" failed "$(state_of 0000:cd:00.0)"
check "mixed: cd reason" "unlock failed (-16)" "$(reason_of 0000:cd:00.0)"
check "mixed: no power off" false "$("$CONTROL" status | jq .power_off_required)"
check "mixed: boot id recorded" boot-1 "$("$CONTROL" status | jq -r .boot_id)"
check "mixed: kernel lines kept in the log" 2 "$(grep -c 'gpu_unlock: unlock' "$GPU_UNLOCK_LOG")"
teardown

# WPR2 message: power off required, reported on the card that logged it.
setup
configure yes 0000:cc:00.0,0000:cd:00.0
early_boot module-present
STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-wpr2.txt "$CONTROL" boot
check "wpr2: cc unlocked" unlocked "$(state_of 0000:cc:00.0)"
check "wpr2: cd failed" failed "$(state_of 0000:cd:00.0)"
check "wpr2: cd reason" "card already initialised since power on (WPR2 enabled); power off first" "$(reason_of 0000:cd:00.0)"
check "wpr2: power off required" true "$("$CONTROL" status | jq .power_off_required)"
teardown

# Firmware load failure stops before any card is touched: both fail, no power off.
setup
configure yes 0000:cc:00.0,0000:cd:00.0
early_boot module-present
STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-firmware.txt "$CONTROL" boot
check "firmware: cc reason" "firmware load failed (-2)" "$(reason_of 0000:cc:00.0)"
check "firmware: cd reason" "firmware load failed" "$(reason_of 0000:cd:00.0)"
check "firmware: no power off" false "$("$CONTROL" status | jq .power_off_required)"
teardown

# A record from another boot is never shown as this boot's result.
setup
configure yes 0000:cc:00.0,0000:cd:00.0
early_boot module-present
"$CONTROL" boot
check "previous boot: unlocked" unlocked "$(state_of 0000:cc:00.0)"
echo boot-2 > "$W/boot_id"
check "new boot: pending" pending "$(state_of 0000:cc:00.0)"
check "new boot: boot id" boot-2 "$("$CONTROL" status | jq -r .boot_id)"
configure no 0000:cc:00.0,0000:cd:00.0
check "new boot, disabled" disabled "$(state_of 0000:cd:00.0)"
teardown

# Status output stays valid JSON when a reason contains quotes.
setup
configure yes 0000:cc:00.0
early_boot module-present
printf '%s\n' '[   41.1] gpu_unlock: no supported card at "0000:cc:00.0"' > "$W/odd.txt"
STUB_UNLOCK_FIXTURE=$W/odd.txt "$CONTROL" boot
check "quotes: valid json" failed "$(state_of 0000:cc:00.0)"
teardown

finish
