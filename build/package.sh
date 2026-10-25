#!/bin/bash
# Package the control script and settings page as gpu-unlock-ui-<plugin version>-x86_64-<build>.txz.
#
# usage: build/package.sh [--build 1] [--out build/out]
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
BUILD=1 OUT=$HERE/out
while [ $# -gt 0 ]; do
  case $1 in
    --build) BUILD=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) sed -n '2,4p' "$0" >&2; exit 2 ;;
  esac
done

VERSION=$(sed -n 's/.*<!ENTITY version *"\([^"]*\)">.*/\1/p' "$ROOT/gpu-unlock.plg")
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/source/." "$STAGE/"
chmod 755 "$STAGE/usr/local/sbin/gpu-unlock-control"
mkdir -p "$STAGE/install" "$OUT"
cat > "$STAGE/install/slack-desc" <<EOF
gpu-unlock-ui: gpu-unlock-ui (GPU Unlock plugin $VERSION)
gpu-unlock-ui:
gpu-unlock-ui: Boot coordination script and settings page for the gpu-unlock
gpu-unlock-ui: Unraid plugin.
gpu-unlock-ui:
gpu-unlock-ui:
gpu-unlock-ui:
gpu-unlock-ui:
gpu-unlock-ui:
gpu-unlock-ui:
gpu-unlock-ui:
EOF

TXZ=$OUT/gpu-unlock-ui-$(echo "$VERSION" | tr - _)-x86_64-$BUILD.txz
python3 "$HERE/mktxz.py" "$STAGE" "$TXZ"
tar -tvJf "$TXZ"
echo "$TXZ"
