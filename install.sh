#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC="$SCRIPT_DIR/incus-limit.sh"
DEST="/usr/local/sbin/incus-limit"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请使用 root 运行安装脚本: sudo ./install.sh" >&2
    exit 1
fi

if [ ! -f "$SRC" ]; then
    echo "未找到源脚本: $SRC" >&2
    exit 1
fi

install -m 0755 "$SRC" "$DEST"

echo "已安装到 $DEST"
echo "运行方式: sudo incus-limit"
