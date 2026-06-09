# incus-limit

交互式 Incus 转发流量并发连接限制脚本。

这个脚本主要面向 `Incus proxy nat=true` 这类场景，用 `iptables/ip6tables` 的 `connlimit` 做目标地址维度的连接数限制。

## 功能

- 支持 IPv4 和 IPv6
- 默认按目标地址总量限制
- 输入网段时可选：
  - 网段内每个 IP 单独限制
  - 整个网段共享一个总限制
- 自动发现 Incus 受管 bridge 网络的 IPv4/IPv6 网段
- 只管理自己挂到 `FORWARD` 上的规则
- 配置保存在 `/var/lib/incus-limit/targets.db`

## 注意事项

- 这个脚本使用的是原始 `connlimit` 语义
- 一旦目标超限，命中目标的现有连接和新连接都可能继续被丢包
- 建议先从较高阈值开始，例如 `500`
- 运行前请确认你理解 `每个目标 IP 单独限制` 和 `整个网段共享一个总限制` 的区别
- 运行一次后，规则会写入当前内核的 `iptables/ip6tables`
- 脚本退出后规则仍然保留，直到你手动删除、重启后未恢复、或被别的防火墙管理工具覆盖

## 依赖

- Linux
- `bash`
- `iptables`
- `ip6tables`
- `awk`
- `grep`
- `mktemp`
- `incus` 可选
  - 仅用于自动发现 Incus bridge 网段
  - 没有 `incus` 也可以手动输入目标

### 一键运行

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-connlimit/main/incus-limit.sh | sudo bash
```

## 其他使用方式

### 克隆后安装

```bash
git clone https://github.com/piphase/incus-connlimit.git
cd incus-connlimit
sudo ./install.sh
sudo incus-limit
```

### 直接安装到 `/usr/local/sbin`

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-connlimit/main/incus-limit.sh -o /tmp/incus-limit.sh
sudo install -m 0755 /tmp/incus-limit.sh /usr/local/sbin/incus-limit
rm -f /tmp/incus-limit.sh
sudo incus-limit
```

### 本地运行

```bash
sudo ./incus-limit.sh
```

### 安装脚本

```bash
sudo ./install.sh
```

安装后可直接执行：

```bash
sudo incus-limit
```

卸载：

```bash
sudo ./uninstall.sh
```

