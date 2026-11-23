#!/usr/bin/env python3
"""Quick fake-capacity check for USB drives on macOS (f3probe-style).

Writes unique 1 MiB blocks at points spread across the whole disk, then
reads them back. A fake drive loses or wraps blocks past its real size.

!!! DESTROYS ALL DATA ON THE TARGET DISK !!!

  diskutil list                                  # find /dev/diskN
  sudo python3 sizecheck.py write  /dev/diskN
  # unplug + replug the drive (click "Ignore" if macOS complains)
  sudo python3 sizecheck.py verify /dev/diskN
"""
import os
import plistlib
import random
import stat
import subprocess
import sys

BLOCK = 1 << 20  # 1 MiB per probe
PROBES = 512     # probe points spread across the disk
SEED = 0xF3F3

GB = 1000 ** 3


def disk_info(path):
    st = os.stat(path)
    if stat.S_ISREG(st.st_mode):  # plain file, for testing
        return st.st_size, path
    if not path.startswith("/dev/disk"):
        sys.exit("Give a whole disk like /dev/disk4 (see `diskutil list`).")
    info = plistlib.loads(
        subprocess.check_output(["diskutil", "info", "-plist", path]))
    # Built-in SD readers report Internal=True, so key off removability.
    if not (info.get("RemovableMediaOrExternalDevice") or info.get("Ejectable")):
        sys.exit(f"{path} is a fixed internal disk. Refusing.")
    if not info.get("WholeDisk", False):
        sys.exit(f"{path} is a partition. Use the whole disk (e.g. /dev/disk4).")
    size = info.get("TotalSize") or info["Size"]
    name = info.get("MediaName", "?")
    print(f"{path}: {name}, claims {size / GB:.1f} GB")
    subprocess.run(["diskutil", "unmountDisk", path], check=False)
    return size, path.replace("/dev/disk", "/dev/rdisk")


def offsets(size):
    n = size // BLOCK
    idx = sorted({round(i * (n - 1) / (PROBES - 1)) for i in range(PROBES)})
    return [i * BLOCK for i in idx]


def pattern(off):
    return random.Random(SEED * 1_000_003 + off).randbytes(BLOCK)


def do_write(path):
    size, raw = disk_info(path)
    if input("ALL DATA on this disk will be destroyed. Type YES: ") != "YES":
        sys.exit("Aborted.")
    offs = offsets(size)
    fd = os.open(raw, os.O_RDWR)
    try:
        for n, off in enumerate(offs, 1):
            try:
                os.pwrite(fd, pattern(off), off)
            except OSError as e:
                print(f"\nwrite error at {off / GB:.2f} GB: {e}")
            print(f"\rwrite {n}/{len(offs)}  @ {off / GB:7.2f} GB", end="", flush=True)
        os.fsync(fd)
    finally:
        os.close(fd)
    print("\nDone. Unplug and replug the drive, then run `verify`.")


def do_verify(path):
    size, raw = disk_info(path)
    offs = offsets(size)
    bad = []
    fd = os.open(raw, os.O_RDONLY)
    try:
        for n, off in enumerate(offs, 1):
            try:
                ok = os.pread(fd, BLOCK, off) == pattern(off)
            except OSError:
                ok = False
            if not ok:
                bad.append(off)
            print(f"\rverify {n}/{len(offs)}  bad={len(bad)}", end="", flush=True)
    finally:
        os.close(fd)
    print()
    if not bad:
        print(f"REAL. All {len(offs)} probes OK across {size / GB:.1f} GB.")
        return
    first = bad[0]
    good_below = [o for o in offs if o < first]
    last_good = good_below[-1] + BLOCK if good_below else 0
    print(f"FAKE or FAULTY. {len(bad)}/{len(offs)} probes failed.")
    print(f"Real usable size is about {last_good / GB:.1f}-{first / GB:.1f} GB "
          f"(claims {size / GB:.1f} GB).")


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("write", "verify"):
        sys.exit(__doc__)
    {"write": do_write, "verify": do_verify}[sys.argv[1]](sys.argv[2])
