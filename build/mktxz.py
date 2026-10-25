#!/usr/bin/env python3
"""Pack a staging directory into a Slackware .txz owned by root.

usage: mktxz.py STAGE_DIR OUTPUT.txz
"""
import os
import sys
import tarfile


def reset(info):
    info.uid = info.gid = 0
    info.uname = info.gname = "root"
    info.mtime = int(os.environ.get("SOURCE_DATE_EPOCH", "0")) or info.mtime
    if info.isdir():
        info.mode = 0o755
    return info


def main(stage, output):
    with tarfile.open(output, "w:xz", format=tarfile.GNU_FORMAT) as tar:
        tar.add(stage, arcname="./", recursive=False, filter=reset)
        for root, dirs, files in os.walk(stage):
            dirs.sort()
            for name in sorted(dirs) + sorted(files):
                path = os.path.join(root, name)
                tar.add(path, arcname=os.path.relpath(path, stage), recursive=False, filter=reset)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    main(sys.argv[1], sys.argv[2])
