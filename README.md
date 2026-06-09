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

## 本地运行

```bash
sudo ./incus-limit.sh
```

## 安装到系统

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

## GitHub 使用方式

### 方式 1：克隆后安装

```bash
git clone https://github.com/piphase/incus-connlimit.git
cd incus-connlimit
sudo ./install.sh
sudo incus-limit
```

### 方式 2：直接一键运行

这个方式不需要先克隆仓库，但要求目标机器使用 `bash`：

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-connlimit/main/incus-limit.sh | sudo bash
```

### 方式 3：直接安装到 `/usr/local/sbin`

```bash
curl -fsSL https://raw.githubusercontent.com/piphase/incus-connlimit/main/incus-limit.sh -o /tmp/incus-limit.sh
sudo install -m 0755 /tmp/incus-limit.sh /usr/local/sbin/incus-limit
rm -f /tmp/incus-limit.sh
sudo incus-limit
```

## 推到 GitHub

当前目录还不是 Git 仓库。你可以在这里直接执行：

```bash
git init -b main
git add .
git commit -m "Initial commit"
git remote add origin git@github.com:piphase/incus-connlimit.git
git push -u origin main
```

如果你用 GitHub CLI：

```bash
git init -b main
git add .
git commit -m "Initial commit"
gh repo create incus-connlimit --public --source=. --remote=origin --push
```
