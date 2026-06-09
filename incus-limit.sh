#!/bin/bash

set -u
set -o pipefail

# ====================================================
# incus-limit - 交互式 Incus 转发流量并发连接限制工具
# 说明:
# 1. 使用原始 connlimit 语义，超过阈值后现有连接也会受影响
# 2. 针对 Incus proxy nat=true，按 conntrack reply 方向中的后端容器地址匹配
# 3. 默认按目标地址总量限制；输入网段时可选“每个 IP 单独”或“整个网段共享”
# 3. 每个目标 IP/网段独立设置阈值
# 4. 仅管理 FORWARD 链中的自有规则
# ====================================================

CHAIN_V4="INCUS-LIMIT-V4"
CHAIN_V6="INCUS-LIMIT-V6"
STATE_DIR="/var/lib/incus-limit"
STATE_FILE="$STATE_DIR/targets.db"
INPUT_FD=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ipt4() {
    iptables -w "$@"
}

ipt6() {
    ip6tables -w "$@"
}

info() {
    printf "%b%s%b\n" "$GREEN" "$1" "$NC"
}

warn() {
    printf "%b%s%b\n" "$YELLOW" "$1" "$NC"
}

error() {
    printf "%b%s%b\n" "$RED" "$1" "$NC" >&2
}

ui_print() {
    printf "%s\n" "$1" >&2
}

ui_printf() {
    printf "$@" >&2
}

init_input() {
    if [ -t 0 ]; then
        INPUT_FD=0
        return 0
    fi

    if [ -r /dev/tty ]; then
        exec 3</dev/tty || {
            error "无法打开交互终端 /dev/tty。"
            exit 1
        }
        INPUT_FD=3
        return 0
    fi

    error "当前脚本需要交互终端。通过管道执行时，请确保有可用的 /dev/tty。"
    exit 1
}

prompt_read() {
    local prompt=$1
    local __var_name=$2
    local __value

    read -r -u "$INPUT_FD" -p "$prompt" __value || return 1
    printf -v "$__var_name" '%s' "$__value"
}

pause_screen() {
    local _
    prompt_read "按回车键继续..." _ || true
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        error "错误: 请使用 root 权限运行此脚本 (sudo ./incus-limit.sh)"
        exit 1
    fi
}

require_commands() {
    local cmd
    for cmd in iptables ip6tables awk grep mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            error "缺少必要命令: $cmd"
            exit 1
        fi
    done
}

ensure_state_dir() {
    mkdir -p "$STATE_DIR" || {
        error "无法创建状态目录: $STATE_DIR"
        exit 1
    }

    if [ ! -f "$STATE_FILE" ]; then
        : > "$STATE_FILE" || {
            error "无法创建状态文件: $STATE_FILE"
            exit 1
        }
    fi

    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

normalize_target() {
    local family=$1
    local target=$2

    if [[ "$target" == */* ]]; then
        canonicalize_cidr_target "$target"
        return 0
    fi

    if [ "$family" = "v6" ]; then
        printf "%s/128\n" "$target"
    else
        printf "%s/32\n" "$target"
    fi
}

canonicalize_cidr_target() {
    local target=$1

    if ! [[ "$target" == */* ]]; then
        printf "%s\n" "$target"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$target" <<'PY' 2>/dev/null || {
import ipaddress
import sys

target = sys.argv[1]
try:
    print(ipaddress.ip_interface(target).network)
except ValueError:
    sys.exit(1)
PY
            printf "%s\n" "$target"
        }
        return 0
    fi

    printf "%s\n" "$target"
}

incus_cli_available() {
    command -v incus >/dev/null 2>&1
}

is_truthy() {
    case "$1" in
        true|TRUE|True|yes|YES|Yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

is_disabled_address() {
    case "$1" in
        ""|none|NONE|None|- ) return 0 ;;
        *) return 1 ;;
    esac
}

discover_incus_targets() {
    local line
    local name
    local net_type
    local managed
    local ipv4
    local ipv6

    incus_cli_available || return 1

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS=, read -r name net_type managed ipv4 ipv6 <<< "$line"
        [ -n "$name" ] || continue
        [ "$net_type" = "bridge" ] || continue
        is_truthy "$managed" || continue

        if ! is_disabled_address "$ipv4"; then
            printf "%s|IPv4|%s\n" "$name" "$(canonicalize_cidr_target "$ipv4")"
        fi

        if ! is_disabled_address "$ipv6"; then
            printf "%s|IPv6|%s\n" "$name" "$(canonicalize_cidr_target "$ipv6")"
        fi
    done < <(incus network list -f csv,noheader -c ntm46 2>/dev/null)
}

prompt_for_target() {
    local prompt=$1
    local entries=()
    local labels=()
    local entry
    local network_name
    local family_label
    local target
    local choice
    local index
    local default_choice=""

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        network_name=${entry%%|*}
        target=${entry#*|}
        family_label=${target%%|*}
        target=${target##*|}
        entries+=("$target")
        labels+=("$network_name $family_label $target")
    done < <(discover_incus_targets 2>/dev/null || true)

    if [ "${#entries[@]}" -gt 0 ]; then
        ui_print "检测到以下 Incus 内网网段:"
        for index in "${!entries[@]}"; do
            ui_printf "%d. %s\n" "$((index + 1))" "${labels[index]}"
        done
        ui_print "0. 手动输入"

        if [ "${#entries[@]}" -eq 1 ]; then
            default_choice="1"
            prompt_read "请选择 [0-1]，直接回车默认 1: " choice || return 1
        else
            prompt_read "请选择 [0-${#entries[@]}]，直接回车默认 0: " choice || return 1
        fi

        choice=${choice:-$default_choice}
        if [ -z "$choice" ] || [ "$choice" = "0" ]; then
            :
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#entries[@]}" ]; then
            printf "%s\n" "${entries[choice - 1]}"
            return 0
        else
            error "无效选项。"
            return 1
        fi
    fi

    prompt_read "$prompt" target || return 1
    printf "%s\n" "$target"
}

validate_limit() {
    local limit=$1
    [[ "$limit" =~ ^[1-9][0-9]*$ ]] && [ "$limit" -le 1000000 ]
}

host_mask_for_family() {
    local family=$1

    if [ "$family" = "v6" ]; then
        printf "128\n"
    else
        printf "32\n"
    fi
}

target_prefix_length() {
    local family=$1
    local target=$2

    if [[ "$target" == */* ]]; then
        printf "%s\n" "${target##*/}"
    else
        host_mask_for_family "$family"
    fi
}

is_host_target() {
    local family=$1
    local target=$2
    local prefix
    local host_mask

    prefix=$(target_prefix_length "$family" "$target")
    host_mask=$(host_mask_for_family "$family")
    [ "$prefix" = "$host_mask" ]
}

validate_mask_for_family() {
    local family=$1
    local mask=$2
    local max_mask

    [[ "$mask" =~ ^[0-9]+$ ]] || return 1
    max_mask=$(host_mask_for_family "$family")
    [ "$mask" -ge 0 ] && [ "$mask" -le "$max_mask" ]
}

mode_label() {
    local mode=$1

    case "$mode" in
        subnet-shared) printf "整个网段共享" ;;
        *) printf "每个目标 IP 单独" ;;
    esac
}

protocol_label() {
    local protocol=$1

    case "$protocol" in
        tcp) printf "TCP" ;;
        udp) printf "UDP" ;;
        *) printf "TCP+UDP" ;;
    esac
}

normalize_protocol() {
    case "${1:-all}" in
        tcp|udp|all) printf "%s\n" "${1:-all}" ;;
        *) printf "all\n" ;;
    esac
}

protocol_rule_args() {
    local protocol
    protocol=$(normalize_protocol "${1:-all}")

    case "$protocol" in
        tcp) printf -- "-p tcp" ;;
        udp) printf -- "-p udp" ;;
        *) printf -- "" ;;
    esac
}

normalize_mode() {
    local family=$1
    local target=$2
    local mode=${3:-per-ip}

    if is_host_target "$family" "$target"; then
        printf "per-ip\n"
        return 0
    fi

    case "$mode" in
        subnet-shared) printf "subnet-shared\n" ;;
        *) printf "per-ip\n" ;;
    esac
}

connlimit_mask_for_target() {
    local family=$1
    local target=$2
    local mode=${3:-per-ip}

    mode=$(normalize_mode "$family" "$target" "$mode")
    if [ "$mode" = "subnet-shared" ]; then
        target_prefix_length "$family" "$target"
    else
        host_mask_for_family "$family"
    fi
}

validate_target() {
    local family=$1
    local target=$2
    local tmp_chain
    local rc

    if [ "$family" = "v6" ]; then
        tmp_chain="ILCHK6_$$_$RANDOM"
        ipt6 -N "$tmp_chain" >/dev/null 2>&1 || return 1
        if ipt6 -A "$tmp_chain" -d "$target" -j RETURN >/dev/null 2>&1; then
            rc=0
        else
            rc=1
        fi
        ipt6 -F "$tmp_chain" >/dev/null 2>&1 || true
        ipt6 -X "$tmp_chain" >/dev/null 2>&1 || true
        return "$rc"
    fi

    tmp_chain="ILCHK4_$$_$RANDOM"
    ipt4 -N "$tmp_chain" >/dev/null 2>&1 || return 1
    if ipt4 -A "$tmp_chain" -d "$target" -j RETURN >/dev/null 2>&1; then
        rc=0
    else
        rc=1
    fi
    ipt4 -F "$tmp_chain" >/dev/null 2>&1 || true
    ipt4 -X "$tmp_chain" >/dev/null 2>&1 || true
    return "$rc"
}

probe_rule_support() {
    local tmp_chain
    local protocol_args

    tmp_chain="ILPROBE4_$$_$RANDOM"
    if ! ipt4 -N "$tmp_chain" >/dev/null 2>&1; then
        error "无法创建临时 IPv4 链，请检查 iptables 是否可用。"
        exit 1
    fi
    protocol_args=$(protocol_rule_args "tcp")
    if ! ipt4 -A "$tmp_chain" -m conntrack --ctdir REPLY -s 127.0.0.1/32 ${protocol_args} -m connlimit --connlimit-saddr --connlimit-above 1 --connlimit-mask 32 -j DROP >/dev/null 2>&1; then
        ipt4 -F "$tmp_chain" >/dev/null 2>&1 || true
        ipt4 -X "$tmp_chain" >/dev/null 2>&1 || true
        error "当前 IPv4 防火墙后端不支持 conntrack/connlimit/DROP 组合规则。"
        exit 1
    fi
    ipt4 -F "$tmp_chain" >/dev/null 2>&1 || true
    ipt4 -X "$tmp_chain" >/dev/null 2>&1 || true

    tmp_chain="ILPROBE6_$$_$RANDOM"
    if ! ipt6 -N "$tmp_chain" >/dev/null 2>&1; then
        error "无法创建临时 IPv6 链，请检查 ip6tables 是否可用。"
        exit 1
    fi
    if ! ipt6 -A "$tmp_chain" -m conntrack --ctdir REPLY -s ::1/128 ${protocol_args} -m connlimit --connlimit-saddr --connlimit-above 1 --connlimit-mask 128 -j DROP >/dev/null 2>&1; then
        ipt6 -F "$tmp_chain" >/dev/null 2>&1 || true
        ipt6 -X "$tmp_chain" >/dev/null 2>&1 || true
        error "当前 IPv6 防火墙后端不支持 conntrack/connlimit/DROP 组合规则。"
        exit 1
    fi
    ipt6 -F "$tmp_chain" >/dev/null 2>&1 || true
    ipt6 -X "$tmp_chain" >/dev/null 2>&1 || true
}

state_has_family() {
    local family=$1
    grep -q "^${family}|" "$STATE_FILE" 2>/dev/null
}

get_state_limit() {
    local family=$1
    local target=$2

    awk -F'|' -v family="$family" -v target="$target" '
        $1 == family && $2 == target { print $3; exit }
    ' "$STATE_FILE"
}

get_state_mode() {
    local family=$1
    local target=$2

    awk -F'|' -v family="$family" -v target="$target" '
        $1 == family && $2 == target {
            if (NF >= 4 && $4 != "") {
                print $4
            } else {
                print "per-ip"
            }
            exit
        }
    ' "$STATE_FILE"
}

get_state_protocol() {
    local family=$1
    local target=$2

    awk -F'|' -v family="$family" -v target="$target" '
        $1 == family && $2 == target {
            if (NF >= 5 && $5 != "") {
                print $5
            } else {
                print "all"
            }
            exit
        }
    ' "$STATE_FILE"
}

list_family_targets() {
    local family=$1

    awk -F'|' -v family="$family" '
        $1 == family && NF >= 3 {
            mode = (NF >= 4 && $4 != "") ? $4 : "per-ip"
            protocol = (NF >= 5 && $5 != "") ? $5 : "all"
            print $2 "|" $3 "|" mode "|" protocol
        }
    ' "$STATE_FILE"
}

upsert_state_entry() {
    local family=$1
    local target=$2
    local limit=$3
    local mode=${4:-per-ip}
    local protocol=${5:-all}
    local tmp_file

    tmp_file=$(mktemp "$STATE_DIR/targets.XXXXXX") || return 1
    awk -F'|' -v family="$family" -v target="$target" -v limit="$limit" -v mode="$mode" -v protocol="$protocol" '
        BEGIN { updated = 0 }
        NF < 3 { next }
        $1 == family && $2 == target {
            if (!updated) {
                print family "|" target "|" limit "|" mode "|" protocol
                updated = 1
            }
            next
        }
        { print $0 }
        END {
            if (!updated) {
                print family "|" target "|" limit "|" mode "|" protocol
            }
        }
    ' "$STATE_FILE" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    mv "$tmp_file" "$STATE_FILE"
}

remove_state_entry() {
    local family=$1
    local target=$2
    local tmp_file

    tmp_file=$(mktemp "$STATE_DIR/targets.XXXXXX") || return 1
    awk -F'|' -v family="$family" -v target="$target" '
        NF >= 3 && !($1 == family && $2 == target) { print $0 }
    ' "$STATE_FILE" > "$tmp_file" || {
        rm -f "$tmp_file"
        return 1
    }

    mv "$tmp_file" "$STATE_FILE"
}

backup_state() {
    local backup_file
    backup_file=$(mktemp "$STATE_DIR/state-backup.XXXXXX") || return 1
    cp "$STATE_FILE" "$backup_file" || {
        rm -f "$backup_file"
        return 1
    }
    printf "%s\n" "$backup_file"
}

restore_state() {
    local backup_file=$1
    cp "$backup_file" "$STATE_FILE"
}

remove_forward_references_v4() {
    local rule
    local delete_rule

    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        delete_rule=${rule/#-A /-D }
        ipt4 $delete_rule >/dev/null 2>&1 || return 1
    done < <(iptables -S FORWARD 2>/dev/null | grep -F " -j $CHAIN_V4" || true)
}

remove_forward_references_v6() {
    local rule
    local delete_rule

    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        delete_rule=${rule/#-A /-D }
        ipt6 $delete_rule >/dev/null 2>&1 || return 1
    done < <(ip6tables -S FORWARD 2>/dev/null | grep -F " -j $CHAIN_V6" || true)
}

ensure_chain_v4() {
    ipt4 -L "$CHAIN_V4" >/dev/null 2>&1 || ipt4 -N "$CHAIN_V4" >/dev/null 2>&1
}

ensure_chain_v6() {
    ipt6 -L "$CHAIN_V6" >/dev/null 2>&1 || ipt6 -N "$CHAIN_V6" >/dev/null 2>&1
}

cleanup_family_v4() {
    remove_forward_references_v4 || return 1
    if ipt4 -L "$CHAIN_V4" >/dev/null 2>&1; then
        ipt4 -F "$CHAIN_V4" >/dev/null 2>&1 || return 1
        ipt4 -X "$CHAIN_V4" >/dev/null 2>&1 || return 1
    fi
}

cleanup_family_v6() {
    remove_forward_references_v6 || return 1
    if ipt6 -L "$CHAIN_V6" >/dev/null 2>&1; then
        ipt6 -F "$CHAIN_V6" >/dev/null 2>&1 || return 1
        ipt6 -X "$CHAIN_V6" >/dev/null 2>&1 || return 1
    fi
}

apply_family_v4() {
    local entry
    local target
    local limit
    local mode
    local protocol
    local mask
    local rule_args

    if ! state_has_family "v4"; then
        cleanup_family_v4
        return $?
    fi

    ensure_chain_v4 || return 1
    remove_forward_references_v4 || return 1
    ipt4 -I FORWARD 1 -j "$CHAIN_V4" >/dev/null 2>&1 || return 1
    ipt4 -F "$CHAIN_V4" >/dev/null 2>&1 || return 1

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        target=${entry%%|*}
        limit=${entry#*|}
        limit=${limit%%|*}
        mode=${entry#*|}
        mode=${mode#*|}
        mode=${mode%%|*}
        protocol=${entry##*|}
        mask=$(connlimit_mask_for_target "v4" "$target" "$mode")
        validate_mask_for_family "v4" "$mask" || return 1
        protocol=$(normalize_protocol "$protocol")
        rule_args=$(protocol_rule_args "$protocol")
        ipt4 -A "$CHAIN_V4" -m conntrack --ctdir REPLY -s "$target" ${rule_args} -m connlimit --connlimit-saddr --connlimit-above "$limit" --connlimit-mask "$mask" -m comment --comment "incus-limit:$target:$limit:$mode:$protocol" -j DROP >/dev/null 2>&1 || return 1
    done < <(list_family_targets "v4")

    ipt4 -A "$CHAIN_V4" -j RETURN >/dev/null 2>&1 || return 1
}

apply_family_v6() {
    local entry
    local target
    local limit
    local mode
    local protocol
    local mask
    local rule_args

    if ! state_has_family "v6"; then
        cleanup_family_v6
        return $?
    fi

    ensure_chain_v6 || return 1
    remove_forward_references_v6 || return 1
    ipt6 -I FORWARD 1 -j "$CHAIN_V6" >/dev/null 2>&1 || return 1
    ipt6 -F "$CHAIN_V6" >/dev/null 2>&1 || return 1

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        target=${entry%%|*}
        limit=${entry#*|}
        limit=${limit%%|*}
        mode=${entry#*|}
        mode=${mode#*|}
        mode=${mode%%|*}
        protocol=${entry##*|}
        mask=$(connlimit_mask_for_target "v6" "$target" "$mode")
        validate_mask_for_family "v6" "$mask" || return 1
        protocol=$(normalize_protocol "$protocol")
        rule_args=$(protocol_rule_args "$protocol")
        ipt6 -A "$CHAIN_V6" -m conntrack --ctdir REPLY -s "$target" ${rule_args} -m connlimit --connlimit-saddr --connlimit-above "$limit" --connlimit-mask "$mask" -m comment --comment "incus-limit:$target:$limit:$mode:$protocol" -j DROP >/dev/null 2>&1 || return 1
    done < <(list_family_targets "v6")

    ipt6 -A "$CHAIN_V6" -j RETURN >/dev/null 2>&1 || return 1
}

apply_all_rules() {
    apply_family_v4 || return 1
    apply_family_v6 || return 1
}

commit_state_change() {
    local backup_file

    backup_file=$(backup_state) || return 1

    "$@" || {
        restore_state "$backup_file" >/dev/null 2>&1 || true
        rm -f "$backup_file"
        return 1
    }

    if apply_all_rules; then
        rm -f "$backup_file"
        return 0
    fi

    restore_state "$backup_file" || true
    apply_all_rules >/dev/null 2>&1 || true
    rm -f "$backup_file"
    return 1
}

add_target() {
    local input_target
    local family
    local target
    local limit
    local old_limit
    local old_mode
    local old_protocol
    local mode="per-ip"
    local mode_choice
    local protocol="tcp"
    local protocol_choice

    input_target=$(prompt_for_target "请输入要限制的目标 IP 或网段 (例如 10.10.2.202 或 10.10.0.0/22): ") || {
        pause_screen
        return
    }
    [ -n "$input_target" ] || return

    prompt_read "请输入单 IP 最大并发连接数 (默认 200): " limit || return
    limit=${limit:-200}

    if [[ "$input_target" == *":"* ]]; then
        family="v6"
    else
        family="v4"
    fi

    target=$(normalize_target "$family" "$input_target")

    if ! validate_limit "$limit"; then
        error "连接数必须是 1 到 1000000 的正整数。"
        pause_screen
        return
    fi

    if ! validate_target "$family" "$target"; then
        error "目标地址格式不合法: $target"
        pause_screen
        return
    fi

    echo "请选择要限制的协议:"
    echo "1. 仅 TCP (默认)"
    echo "2. 仅 UDP"
    echo "3. TCP + UDP"
    prompt_read "请选择 [1-3]，直接回车默认 1: " protocol_choice || return

    case "$protocol_choice" in
        2) protocol="udp" ;;
        3) protocol="all" ;;
        ""|1) protocol="tcp" ;;
        *)
            error "无效选项。"
            pause_screen
            return
            ;;
    esac

    if ! is_host_target "$family" "$target"; then
        echo "请选择网段计数方式:"
        echo "1. 每个目标 IP 单独限制 (默认)"
        echo "2. 整个网段共享一个总限制"
        prompt_read "请选择 [1-2]，直接回车默认 1: " mode_choice || return

        case "$mode_choice" in
            2) mode="subnet-shared" ;;
            ""|1) mode="per-ip" ;;
            *)
                error "无效选项。"
                pause_screen
                return
                ;;
        esac
    fi

    mode=$(normalize_mode "$family" "$target" "$mode")
    protocol=$(normalize_protocol "$protocol")
    old_limit=$(get_state_limit "$family" "$target")
    old_mode=$(get_state_mode "$family" "$target")
    old_protocol=$(get_state_protocol "$family" "$target")
    if ! commit_state_change upsert_state_entry "$family" "$target" "$limit" "$mode" "$protocol"; then
        error "保存配置或应用规则失败，已回滚到变更前状态。"
        pause_screen
        return
    fi

    if [ -n "$old_limit" ] && { [ "$old_limit" != "$limit" ] || [ "$old_mode" != "$mode" ] || [ "$old_protocol" != "$protocol" ]; }; then
        info "已更新 $target 的限制: limit $old_limit -> $limit，模式 $(mode_label "$old_mode") -> $(mode_label "$mode")，协议 $(protocol_label "$old_protocol") -> $(protocol_label "$protocol")"
    elif [ -n "$old_limit" ]; then
        warn "目标 $target 已存在，限制保持为 $limit，模式为 $(mode_label "$mode")，协议为 $(protocol_label "$protocol")。"
    else
        info "已添加 $target，最大并发连接数为 $limit，模式为 $(mode_label "$mode")，协议为 $(protocol_label "$protocol")。"
    fi

    pause_screen
}

remove_target() {
    local input_target
    local family
    local target

    prompt_read "请输入要解除限制的目标 IP 或网段: " input_target || return
    [ -n "$input_target" ] || return

    if [[ "$input_target" == *":"* ]]; then
        family="v6"
    else
        family="v4"
    fi

    target=$(normalize_target "$family" "$input_target")

    if [ -z "$(get_state_limit "$family" "$target")" ]; then
        warn "未找到目标 $target 的配置。"
        pause_screen
        return
    fi

    if ! commit_state_change remove_state_entry "$family" "$target"; then
        error "删除配置或应用规则失败，已回滚到变更前状态。"
        pause_screen
        return
    fi

    info "已解除对 $target 的限制。"
    pause_screen
}

print_state_section() {
    local family=$1
    local title=$2
    local label=$3
    local found=0
    local entry
    local target
    local limit
    local mode
    local protocol
    local mask

    printf "\n%b=== %s ===%b\n" "$YELLOW" "$title" "$NC"
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        found=1
        target=${entry%%|*}
        limit=${entry#*|}
        limit=${limit%%|*}
        mode=${entry#*|}
        mode=${mode#*|}
        mode=${mode%%|*}
        protocol=${entry##*|}
        mask=$(connlimit_mask_for_target "$family" "$target" "$mode")
        printf "%s  %-32s limit=%s  mode=%s  protocol=%s  mask=%s\n" "$label" "$target" "$limit" "$(mode_label "$mode")" "$(protocol_label "$protocol")" "$mask"
    done < <(list_family_targets "$family")

    if [ "$found" -eq 0 ]; then
        echo "无"
    fi
}

show_status() {
    print_state_section "v4" "已配置的 IPv4 目标" "IPv4"
    printf "\n%b=== IPv4 实时计数链 ===%b\n" "$YELLOW" "$NC"
    iptables -nvL "$CHAIN_V4" --line-numbers 2>/dev/null || echo "未启用"

    print_state_section "v6" "已配置的 IPv6 目标" "IPv6"
    printf "\n%b=== IPv6 实时计数链 ===%b\n" "$YELLOW" "$NC"
    ip6tables -nvL "$CHAIN_V6" --line-numbers 2>/dev/null || echo "未启用"

    printf "\n说明: 当前脚本使用原始 connlimit 语义，并针对 Incus proxy nat=true 按 conntrack reply 方向中的后端容器地址匹配。默认限制 TCP，可选 UDP 或 TCP+UDP。目标超限后，命中该目标的现有连接和新连接都可能继续被丢包。\n\n"
    pause_screen
}

flush_all() {
    local confirm

    prompt_read "警告: 将删除所有 incus-limit 规则和状态记录。确定吗？(y/n): " confirm || return
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "已取消。"
        pause_screen
        return
    fi

    if ! cleanup_family_v4; then
        error "清理 IPv4 规则失败。"
        pause_screen
        return
    fi

    if ! cleanup_family_v6; then
        error "清理 IPv6 规则失败。"
        pause_screen
        return
    fi

    : > "$STATE_FILE" || {
        error "清空状态文件失败。"
        pause_screen
        return
    }

    info "所有 incus-limit 规则已清空。"
    pause_screen
}

main_menu() {
    local choice

    while true; do
        if [ -t 1 ]; then
            clear
        fi

        printf "%b==========================================%b\n" "$GREEN" "$NC"
        printf "%b       Incus 容器网络限流管理工具         %b\n" "$GREEN" "$NC"
        printf "%b==========================================%b\n" "$GREEN" "$NC"
        echo "1. 添加/更新限流目标 (支持自动发现 Incus 网段)"
        echo "2. 解除特定目标的限流"
        echo "3. 查看当前限流状态与拦截统计"
        echo "4. 一键清空并关闭所有限流"
        echo "0. 退出"
        printf "%b==========================================%b\n" "$GREEN" "$NC"
        prompt_read "请选择操作 [0-4]: " choice || {
            echo ""
            exit 1
        }

        case "$choice" in
            1) add_target ;;
            2) remove_target ;;
            3) show_status ;;
            4) flush_all ;;
            0)
                echo "退出。"
                exit 0
                ;;
            *)
                error "无效选项，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

require_root
require_commands
init_input
ensure_state_dir
probe_rule_support
if ! apply_all_rules; then
    error "初始化现有限流规则失败，请检查当前防火墙状态或先执行清空。"
    exit 1
fi
main_menu
