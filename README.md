# tailnet-bridge

用 Tailscale 把 **VPS** 与**内部服务器**连起来,内部服务器不暴露任何公网端口。
之后在 VPS 上 `ssh internal` 即可;推荐在内部服务器的 tmux 里运行 Claude Code。

## 使用

**1. VPS 上**

```bash
git clone <本仓库> && cd tailnet-bridge
./setup.sh vps
```

脚本会:安装并登录 Tailscale → 生成专用 SSH 密钥 → 打印要在内部服务器执行的命令 → **等待内部服务器连通**。

**2. 内部服务器上**(执行 VPS 打印出来的那条命令)

```bash
git clone <本仓库> && cd tailnet-bridge
./setup.sh internal --pubkey 'ssh-ed25519 AAAA... tailnet-bridge@vps'
```

脚本会:安装并登录 Tailscale → 确保 sshd 运行 → 安装 tmux → 授权 VPS 公钥。

**3. 回到 VPS**:检测到连通后自动写入 `~/.ssh/config`,然后:

```bash
ssh internal
ssh -t internal 'tmux new -As cc'    # 在 tmux 里跑 claude,断线不丢任务
```

两边的 Tailscale 登录都会打印一个授权链接,在任意浏览器打开、登录**同一个账号**即可。
也可预先 `export TS_AUTHKEY=tskey-...` 免浏览器。

## 选项

| 命令 | 参数 |
|---|---|
| `setup.sh vps` | `--name vps` 本机 tailnet 名 · `--peer internal` 等待的对端名 · `--user` 内部服务器用户名 · `--alias internal` ssh 别名 · `--timeout 秒` |
| `setup.sh internal` | `--name internal` · `--pubkey '...'` · `--user` 授权给哪个本地用户(默认当前用户) · `--rootless` 无 root/sudo 模式 |

自建 Headscale:`export TS_LOGIN_SERVER=https://headscale.example.com` 后再运行。
脚本可重复执行(幂等)。

## 没有 root / sudo(`--rootless`)

内部服务器没有 sudo 时,加 `--rootless`:

```bash
./setup.sh internal --rootless --pubkey 'ssh-ed25519 AAAA...'
```

- 下载 tailscale 静态二进制到 `~/.local/share/tailnet-bridge`,以 **userspace 网络模式**运行(无需 TUN/root)。
- 后台服务优先用 `systemd --user`(并尝试 `loginctl enable-linger`),不可用则退回 `nohup`(重启后需重跑脚本)。
- 通过 `tailscale serve` 把 tailnet:22 转发到本机:本机 sshd 在 22 端口则直接转发,否则自己起一个仅监听 127.0.0.1:2222 的用户态 sshd。
- 公钥的来源限制为回环地址(`from="127.0.0.1,::1"`),因为转发后 sshd 看到的来源是本机。
- 前提:机器上已有 `curl`、`python3`,以及(若系统 sshd 未运行)`/usr/sbin/sshd`;`tmux` 缺失只会提示。
- VPS 端不需要任何改动,仍用 `./setup.sh vps`。

## 安全说明

- 内部服务器只做出站连接,公网上看不到它;内网 IP 不会公开(tailnet 内使用 100.x 虚拟地址)。
- Tailscale 控制面能看到设备名、账号、出口 IP 等元数据,看不到流量内容。要完全自控请用 Headscale。
- 授权的公钥带有 `from="100.64.0.0/10,..."`,即使泄露也只能在 tailnet 内使用。
- VPS 专用密钥 `~/.ssh/id_ed25519_tailnet-bridge` 无口令,便于 Claude Code 自动化,请只用于此用途。

## qemu 虚拟机

只需宿主机(内部服务器)加入 tailnet,虚拟机经宿主机跳转:

```
Host vm1
    HostName 192.168.122.10
    User dev
    ProxyJump internal
```

## 排查

- 脚本卡在 "尚未出现在 tailnet":内部服务器的 Tailscale 还没登录,或登录了不同账号;若主机名冲突会变成 `internal-1`,用 `--peer internal-1`。
- "在线,SSH 尚不可用":用户名不一致(用 `--user`),或 sshd 未运行,或公钥未授权。
- 查看路径与延迟:`tailscale status`(direct / relay)、`tailscale ping internal`。
