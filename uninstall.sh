#!/bin/bash

set -euo pipefail

DEST="/usr/local/sbin/incus-limit"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "请使用 root 运行卸载脚本: sudo ./uninstall.sh" >&2
    exit 1
fi

if [ -e "$DEST" ]; then
    rm -f "$DEST"
    echo "已删除 $DEST"
else
    echo "未发现已安装文件: $DEST"
fi
