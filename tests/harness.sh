# Fake Unraid root and stub commands shared by the gpu-unlock-control tests.
# The stubs record unlock, nvidia and cdi events; they do not model the unlock itself.

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
CONTROL=$ROOT_DIR/source/usr/local/sbin/gpu-unlock-control
FIXTURES=$ROOT_DIR/tests/fixtures
FAILURES=0

setup() {
  W=$(mktemp -d "${TMPDIR:-/tmp}/gpu-unlock-test.XXXXXX")
  mkdir -p "$W/bin" "$W/sys/pci" "$W/sys/module" "$W/etc/modprobe.d" "$W/boot/modprobe.d" "$W/run" "$W/drivers/nvidia"
  echo boot-1 > "$W/boot_id"
  : > "$W/events"
  : > "$W/kmsg"
  : > "$W/uuids"
  export GPU_UNLOCK_PLUGIN_DIR=$W/boot/plugins/gpu-unlock
  export GPU_UNLOCK_BOOT_MODPROBE=$W/boot/modprobe.d
  export GPU_UNLOCK_ETC_MODPROBE=$W/etc/modprobe.d
  export GPU_UNLOCK_SYSFS_PCI=$W/sys/pci
  export GPU_UNLOCK_SYSFS_MODULE=$W/sys/module
  export GPU_UNLOCK_BOOT_ID_FILE=$W/boot_id
  export GPU_UNLOCK_RUN_DIR=$W/run
  export GPU_UNLOCK_LOG=$W/gpu-unlock.log
  export GPU_UNLOCK_KERNEL=6.18.54-Unraid
  export GPU_UNLOCK_NOTIFY=$W/bin/notify
  export W
  # Both unlock modules installed for this kernel unless a test removes one.
  export STUB_HAVE_GPU_UNLOCK=yes
  export STUB_HAVE_TURING_UNLOCK=yes
  export STUB_UNLOCK_FIXTURE=$FIXTURES/kmsg-ok.txt
  export STUB_TURING_FIXTURE=$FIXTURES/kmsg-turing-ok.txt
  export STUB_UNLOCK_RC=0
  # Modules "modprobe -R <modalias>" resolves for an NVIDIA display device.
  export STUB_ALIAS_MODULES=nvidia

  cat > "$W/bin/dmesg" <<'EOF'
#!/bin/bash
cat "$W/kmsg"
EOF
  cat > "$W/bin/modinfo" <<'EOF'
#!/bin/bash
[ "$1" = -k ] && shift 2
[ "$1" = -n ] && shift
case $1 in
  gpu_unlock) [ "$STUB_HAVE_GPU_UNLOCK" = yes ] && echo /lib/modules/extra/gpu_unlock.ko ;;
  turing_unlock) [ "$STUB_HAVE_TURING_UNLOCK" = yes ] && echo /lib/modules/extra/turing_unlock.ko ;;
  nvidia) [ -f "$W/nvidia-installed" ] && echo /lib/modules/extra/nvidia.ko ;;
  *) false ;;
esac
EOF
  # Honours "install <module> /bin/false" lines the way modprobe would.
  cat > "$W/bin/modprobe" <<'EOF'
#!/bin/bash
if [ "$1" = -R ]; then
  case $2 in pci:v000010DE*) printf '%s\n' $STUB_ALIAS_MODULES ;; *) exit 1 ;; esac
  exit 0
fi
mod=$1; shift
grep -qs "^install $mod /bin/false" "$GPU_UNLOCK_ETC_MODPROBE"/*.conf && exit 1
case $mod in
  nvidia_drm)
    [ -f "$W/nvidia-installed" ] || exit 1
    "$0" nvidia || exit 1
    echo nvidia_drm >> "$W/events"
    ;;
  nouveau|nvidiafb)
    echo "$mod" >> "$W/events"
    ;;
  gpu_unlock)
    echo "unlock $mod $*" >> "$W/events"
    [ "$STUB_UNLOCK_RC" = 0 ] || exit "$STUB_UNLOCK_RC"
    cat "$STUB_UNLOCK_FIXTURE" >> "$W/kmsg"
    mkdir -p "$W/sys/module/gpu_unlock"
    ;;
  turing_unlock)
    echo "unlock $mod $*" >> "$W/events"
    cat "$STUB_TURING_FIXTURE" >> "$W/kmsg"
    mkdir -p "$W/sys/module/turing_unlock"
    ;;
  nvidia)
    [ -f "$W/nvidia-installed" ] || exit 1
    [ -d "$W/sys/module/nvidia" ] && exit 0
    echo nvidia >> "$W/events"
    mkdir -p "$W/sys/module/nvidia"
    ;;
  *) exit 1 ;;
esac
EOF
  # NVML loads the driver through nvidia-modprobe when it is not loaded yet.
  cat > "$W/bin/nvidia-ctk" <<'EOF'
#!/bin/bash
[ -d "$W/sys/module/nvidia" ] || modprobe nvidia || exit 1
echo cdi >> "$W/events"
EOF
  # Reports UUIDs only once nvidia is loaded, from "BUS ID, UUID" lines in $W/uuids.
  cat > "$W/bin/nvidia-smi" <<'EOF'
#!/bin/bash
[ -d "$W/sys/module/nvidia" ] || exit 9
cat "$W/uuids"
EOF
  cat > "$W/bin/notify" <<'EOF'
#!/bin/bash
echo notify >> "$W/events"
EOF
  cat > "$W/bin/lspci" <<'EOF'
#!/bin/bash
echo "${2#0000:} VGA compatible controller: NVIDIA Corporation GA102 [GeForce RTX 3080] (rev a1)"
EOF
  chmod +x "$W"/bin/*
  export PATH=$W/bin:$PATH

  add_gpu 0000:c5:00.0 1e07
  add_gpu 0000:c8:00.0 1e07
  add_gpu 0000:cc:00.0 2206
  add_gpu 0000:cd:00.0 2206
  cat "$FIXTURES/kmsg-before.txt" > "$W/kmsg"
}

teardown() {
  rm -rf "$W"
}

# add_gpu BDF DEVICE [VENDOR [CLASS]]: RTX 3080 (2206) and RTX 2080 Ti (1e07) get the
# subsystem IDs of the validation server's cards, NVIDIA cards a UUID of GPU-test-BDF.
add_gpu() {
  mkdir -p "$W/sys/pci/$1"
  echo "0x${3:-10de}" > "$W/sys/pci/$1/vendor"
  echo "0x$2" > "$W/sys/pci/$1/device"
  echo "0x${4:-030000}" > "$W/sys/pci/$1/class"
  echo "0x${3:-10de}" > "$W/sys/pci/$1/subsystem_vendor"
  case $2 in 2206) echo 0x146d ;; 1e07) echo 0x12fa ;; *) echo 0x0000 ;; esac > "$W/sys/pci/$1/subsystem_device"
  grep -v "$(echo "$1" | sed 's/^0000://' | tr a-f A-F)\$" "$W/uuids" | grep -v ", GPU-test-$1\$" > "$W/uuids.tmp"
  mv "$W/uuids.tmp" "$W/uuids"
  [ "${3:-10de}" = 10de ] && [ "${4:-030000}" = 030000 ] && \
    echo "0000$(echo "$1" | tr a-f A-F), GPU-test-$1" >> "$W/uuids"
  echo "pci:v0000$(echo "${3:-10de}" | tr a-f A-F)d0000$(echo "$2" | tr a-f A-F)sv00001458sd00004057bc03sc00i00" > "$W/sys/pci/$1/modalias"
}

bind_gpu() {
  ln -s "$W/drivers/$2" "$W/sys/pci/$1/driver"
}

# The saved entry for the card now at an address: GPU-test-BDF@BDF@IDS, as the page saves it.
entry() {
  local d=$W/sys/pci/$1 v
  v() { sed 's/^0x//' "$d/$1"; }
  printf 'GPU-test-%s@%s@%s:%s@%s:%s' "$1" "$1" "$(v vendor)" "$(v device)" "$(v subsystem_vendor)" "$(v subsystem_device)"
}

# configure ENABLED TARGETS: addresses become full entries; "legacy:" keeps the rest as is.
configure() {
  local targets="" t
  for t in $(echo "$2" | tr , ' '); do
    case $t in
      legacy:*) t=${t#legacy:} ;;
      *@*) ;;
      *) t=$(entry "$t") ;;
    esac
    targets="$targets${targets:+,}$t"
  done
  mkdir -p "$GPU_UNLOCK_PLUGIN_DIR"
  printf 'enabled="%s"\ntargets="%s"\n' "$1" "$targets" > "$GPU_UNLOCK_PLUGIN_DIR/settings.cfg"
}

saved_targets() {
  sed -n 's/^targets="\(.*\)"$/\1/p' "$GPU_UNLOCK_PLUGIN_DIR/settings.cfg"
}

# rc.local continues with nvidia-driver.plg after gpu-unlock.plg, whatever it returned.
# Mirrors its two branches: install the package and modprobe, or only generate CDI.
nvidia_driver_stage() {
  if ! modinfo nvidia > /dev/null 2>&1; then
    touch "$W/nvidia-installed"
    modprobe nvidia
  fi
  nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
}

# What the earlier boot stages leave behind: the driver package is installed
# (module present) and Unraid copied config/modprobe.d to /etc/modprobe.d.
early_boot() {
  [ "$1" = module-present ] && touch "$W/nvidia-installed"
  cp "$GPU_UNLOCK_BOOT_MODPROBE"/*.conf "$GPU_UNLOCK_ETC_MODPROBE"/ 2> /dev/null
  return 0
}

events() {
  tr '\n' ' ' < "$W/events" | sed 's/ $//'
}

state_of() {
  "$CONTROL" status | jq -r --arg p "$1" '.targets[] | select(.pci == $p) | .state'
}

unlocker_of() {
  "$CONTROL" status | jq -r --arg p "$1" '.targets[] | select(.pci == $p) | .unlocker // ""'
}

reason_of() {
  "$CONTROL" status | jq -r --arg p "$1" '.targets[] | select(.pci == $p) | .reason // ""'
}

check() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "     expected: $expected"
    echo "     actual:   $actual"
    FAILURES=$((FAILURES + 1))
  fi
}

finish() {
  if [ $FAILURES -ne 0 ]; then
    echo "$FAILURES failed"
    exit 1
  fi
  echo "all passed"
}
