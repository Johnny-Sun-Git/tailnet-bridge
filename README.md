# tailnet-bridge

用 Tailscale 把 **VPS** 和**内部服务器**连起来,内部服务器不暴露任何公网端口。
之后在 VPS 上 `ssh internal` 即可;推荐在内部服务器的 tmux 里运行 Claude Code。

| | VPS | 内部服务器 |
|---|---|---|
| 权限 | 需要 root/sudo | **不需要** root/sudo |
| 命令 | `./setup.sh vps` | `./setup.sh internal --pubkey '...'` |

## 一次配好(3 步)

**前提**:两台机器能访问外网;有一个 Tailscale 账号(两边登录**同一个**账号);内部服务器已有 `curl`/`wget`、`tar`、`git`、`sshd`。

### 1. VPS 上

```bash
git clone https://github.com/Johnny-Sun-Git/tailnet-bridge.git && cd tailnet-bridge
./setup.sh vps
```

按提示输入「内部服务器上的登录用户名」。脚本会安装并登录 Tailscale(终端打印授权链接,在浏览器打开),
生成专用 SSH 密钥,然后**打印一条要在内部服务器执行的完整命令(已含公钥)**,并停在那里等待。

### 2. 内部服务器上(无需 root/sudo)

VPS 会打印一个**粘贴块**(同时保存在 VPS 的 `~/tailnet-bridge-internal.txt`,随时 `cat` 重看)。
**整段原样复制,粘贴到内部服务器终端回车**,不用改任何东西。形如:

```bash
mkdir -p ~/.cache && cat > ~/.cache/tnb-vps.pub <<'TNB_KEY'
ssh-ed25519 AAAA... tailnet-bridge@vps
TNB_KEY
git -C ~/tailnet-bridge pull -q 2>/dev/null || git clone -q https://github.com/Johnny-Sun-Git/tailnet-bridge.git ~/tailnet-bridge
cd ~/tailnet-bridge && ./setup.sh internal --name internal --pubkey-file ~/.cache/tnb-vps.pub
```

公钥通过 heredoc 写入文件,不会有引号/长行问题;脚本还会校验公钥完整性(复制被截断会明确报错)。
终端会打印 Tailscale 授权链接,在浏览器打开并登录**同一个账号**。脚本会自动:
下载 tailscale 到 `~/.local/share/tailnet-bridge`(userspace 模式)→ 把 tailnet:22 转发到本机 sshd → 授权 VPS 公钥。

**内部服务器只需要**:`curl`(或 `wget`)、`tar`、`git`、已有的 `sshd`(或 `/usr/sbin/sshd`)。
**不需要** root、sudo、python3,也不会安装任何系统软件包。

### 3. 回到 VPS

等待中的脚本检测到连通后,自动写入 `~/.ssh/config`,并**自动做网络质量测试**。之后:

```bash
ssh internal
ssh -t internal 'tmux new -As cc'    # 在 tmux 里跑 claude,断线不丢任务
```

## 网络质量测试

`setup.sh vps` 完成时会自动运行,也可随时重测:

```bash
./setup.sh check                       # 默认: 20 个 ping、传 10MB
./setup.sh check --count 50 --size 50  # 更久、更准
```

输出内容:路径(直连/中继)、延迟(最小/平均/最大/抖动)、丢包、SSH 新连接与复用连接耗时、上传/下载吞吐,以及结论。
参考(同一条链路的实测):直连、平均 236ms、抖动 0.4ms、0% 丢包;SSH 新连接约 2.7s、复用连接约 0.5s——
延迟由物理距离决定,抖动和丢包才反映链路是否稳定。

## 选项

| 命令 | 参数 |
|---|---|
| `vps` | `--user` 内部服务器用户名 · `--name vps` 本机 tailnet 名 · `--peer internal` 等待的对端名 · `--alias internal` ssh 别名 · `--timeout 秒` · `--no-check` 跳过测试 |
| `internal` | `--pubkey-file 文件` 或 `--pubkey '...'` VPS 打印的公钥 · `--name internal` · `--key-timeout 秒` · `--system` 系统级安装(需 root/sudo) |
| `check` | `--peer` · `--alias` · `--count` ping 次数 · `--size` 传输 MB 数 |

环境变量:`TS_AUTHKEY=tskey-...` 免浏览器登录;`TS_LOGIN_SERVER=https://...` 使用自建 Headscale。
所有命令可重复执行(幂等)。

## 工作原理

- 内部服务器只做出站连接,公网上看不到它;内网 IP 不会公开(tailnet 内用 100.x 虚拟地址)。
- 内部服务器无 root:tailscaled 以 userspace 模式运行(优先 `systemd --user` + linger,否则 `nohup`),
  `tailscale serve` 把 tailnet:22 转发到本机 sshd(本机没有 sshd 在 22 时,自起仅监听 127.0.0.1:2222 的用户态 sshd)。
- 授权的公钥带来源限制:无 root 时 `from="127.0.0.1,::1"`(转发后来源是本机);`--system` 时 `from="100.64.0.0/10,..."`。
- 私钥始终留在 VPS(`~/.ssh/id_ed25519_tailnet-bridge`,无口令,便于 Claude Code 自动化,请只用于此用途),不会传输。
- Tailscale 控制面能看到设备名、账号、出口 IP 等元数据,看不到流量内容。要完全自控请用 Headscale。

## 公钥怎么到内部服务器

默认就是上面「粘贴块里带公钥」,最可靠。另外还有两条自动兜底(尽力而为,依赖环境):

- 内部服务器省略 `--pubkey` 时,会等待 VPS 经 Tailscale 文件传输(Taildrop)发来公钥。
- VPS 等待约 1 分钟仍被拒绝、且内部 sshd 允许密码登录时,会询问是否用内部账号的密码一次性写入公钥。

## qemu 虚拟机

只需宿主机(内部服务器)加入 tailnet,虚拟机经宿主机跳转:

```
Host vm1
    HostName 192.168.122.10
    User dev
    ProxyJump internal
```

## 排查

- 停在「尚未出现在 tailnet」:内部服务器的 Tailscale 还没登录,或登录了不同账号;主机名冲突会变成 `internal-1`,用 `--peer internal-1`。
- 「在线,SSH 尚不可用: Permission denied」:公钥还没授权(在内部服务器粘贴 VPS 打印的那一段),或 `--user` 用户名不一致。
- 「Connection timed out」:内部服务器上的转发还没配好(正在执行 `setup.sh internal` 时是正常的)。
- 内部服务器没有 `tmux`:无 root 无法代装,请让管理员安装,或直接 `ssh internal` 后运行。
- 内部服务器重启后连不上:无 `systemd --user`/linger 时需要重跑一次 `./setup.sh internal --pubkey ...`。
- 延迟高:`tailscale ping internal` 看是直连还是 DERP 中继;直连时延迟即物理链路延迟。
