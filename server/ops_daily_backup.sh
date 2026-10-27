#!/usr/bin/env bash
# 每日备份账号/房间/快照数据，保留最近 14 份。建议 root 执行（数据文件属主 root）。
set -euo pipefail
SRC=/var/lib/goalday-sync
DST=/var/backups/goalday
mkdir -p "$DST"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$DST/goalday-$TS.tar.gz"
tar -czf "$OUT" -C "$SRC" accounts.json rooms.json data
chmod 600 "$OUT"
ls -1t "$DST"/goalday-*.tar.gz | tail -n +15 | xargs -r rm -f
echo "$OUT"