# -*- coding: utf-8 -*-
"""从备份包做一次只读恢复演练：解包、校验 JSON、统计账号/房间/快照数量。"""
import json
import pathlib
import sys
import tarfile
import tempfile


def main(path):
    tmp = tempfile.mkdtemp(prefix="goalday-drill-")
    with tarfile.open(path) as tar:
        try:
            tar.extractall(tmp, filter="data")
        except TypeError:  # Python < 3.12 没有 filter 参数
            tar.extractall(tmp)
    base = pathlib.Path(tmp)
    acc = json.loads((base / "accounts.json").read_text("utf-8"))
    rooms = json.loads((base / "rooms.json").read_text("utf-8"))
    snaps = sorted((base / "data").glob("*.json"))
    for s in snaps:
        json.loads(s.read_text("utf-8"))
    print(f"accounts={len(acc)} rooms={len(rooms)} snapshots={len(snaps)}")
    if not acc or not isinstance(rooms, list):
        print("restore drill FAILED: 数据结构异常")
        return 1
    print("restore drill OK")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python3 ops_restore_drill.py <backup.tar.gz>")
        sys.exit(2)
    sys.exit(main(sys.argv[1]))