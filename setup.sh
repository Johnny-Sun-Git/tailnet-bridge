#!/usr/bin/env bash
# tailnet-bridge: 通过 Tailscale 把 VPS 与内部服务器连起来(内部服务器不暴露公网端口)。
#
#   VPS 上:        ./setup.sh vps
#   内部服务器上:  ./setup.sh internal --pubkey '<VPS 脚本打印的公钥>'
#
# 详见 README.md
set -euo pipefail

TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-}"   # 使用 Headscale 时填写
TS_AUTHKEY="${TS_AUTHKEY:-}"             # 可选: 免浏览器登录
KEY_NAME="id_ed25519_tailnet-bridge"
TAILNET_FROM='100.64.0.0/10,fd7a:115c:a1e0::/48'

log()  { printf '\033[1;34m[bridge]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bridge]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bridge] 错误:\033[0m %s\n' "$*" >&2; exit 1; }

ROOTLESS=0
RL_DIR="${TNB_HOME:-$HOME/.local/share/tailnet-bridge}"   # 无 root 模式的安装目录
RL_SOCK="$RL_DIR/tailscaled.sock"

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]] && command -v sudo >/dev/null; then SUDO="sudo"; fi

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 || -n "$SUDO" ]] || die "需要 root 或 sudo"
}

ts() {
  if (( ROOTLESS )); then "$RL_DIR/bin/tailscale" --socket="$RL_SOCK" "$@"
  else $SUDO tailscale "$@"; fi
}

usage() {
  cat <<'EOF'
用法:
  ./setup.sh vps      [--name vps] [--peer internal] [--user 用户名] [--alias internal] [--timeout 秒]
  ./setup.sh internal [--name internal] [--pubkey 'ssh-ed25519 ...'] [--key-timeout 秒] [--user 用户名] [--system]

  公钥默认由 VPS 通过 Tailscale 文件传输(Taildrop)自动发给 internal;--pubkey 仅作手动备选

  internal 默认无需 root/sudo: tailscale 以 userspace 模式运行在 ~/.local/share/tailnet-bridge
  --system    改为系统级安装(需要 root/sudo): 安装软件包、systemd 服务、TUN 网卡

环境变量:
  TS_AUTHKEY        Tailscale auth key(可选,免浏览器登录)
  TS_LOGIN_SERVER   自建 Headscale 地址(可选)
EOF
}

# ---------- 公共 ----------
pkg_install() {
  if   command -v apt-get >/dev/null; then $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "$@"
  elif command -v dnf     >/dev/null; then $SUDO dnf install -y -q "$@"
  elif command -v yum     >/dev/null; then $SUDO yum install -y -q "$@"
  elif command -v pacman  >/dev/null; then $SUDO pacman -S --noconfirm --needed "$@"
  elif command -v zypper  >/dev/null; then $SUDO zypper -n install "$@"
  else die "未识别的包管理器,请手动安装: $*"; fi
}

need_basics() {
  local c
  for c in curl python3; do
    command -v "$c" >/dev/null && continue
    (( ROOTLESS )) && die "无 root 模式无法安装软件,请先让管理员安装: $c(或改用 --system)"
    pkg_install "$c"
  done
}

install_tailscale() {
  if command -v tailscale >/dev/null; then
    log "tailscale 已安装: $(tailscale version | head -1)"
  else
    log "安装 tailscale ..."
    curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  fi
  if command -v systemctl >/dev/null; then
    $SUDO systemctl enable --now tailscaled >/dev/null 2>&1 || true
  fi
  # 等 tailscaled 就绪(未登录时 status 也会返回,只要能拿到 BackendState 即可)
  local i
  for i in $(seq 1 20); do
    [[ -n "$(backend_state)" ]] && return 0
    sleep 1
  done
  die "tailscaled 未运行(容器/无 systemd 环境请手动启动 tailscaled)"
}

backend_state() {
  ts status --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
}

tailscale_login() {
  local name="$1"
  if [[ "$(backend_state)" == "Running" ]]; then
    log "tailscale 已登录,设置主机名为 $name"
    ts set --hostname="$name" || true
    return 0
  fi
  local args=(up --hostname="$name")
  [[ -n "$TS_AUTHKEY" ]]       && args+=(--authkey="$TS_AUTHKEY")
  [[ -n "$TS_LOGIN_SERVER" ]]  && args+=(--login-server="$TS_LOGIN_SERVER")
  log "登录 Tailscale。若出现 https://login.tailscale.com/... 链接,请在任意浏览器中打开并授权(命令会阻塞到授权完成)"
  ts "${args[@]}"
}

# 输出 "online|offline <ipv4>";找不到 peer 则无输出
peer_info() {
  ts status --json 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1].lower()
d = json.load(sys.stdin)
for p in (d.get("Peer") or {}).values():
    hn = (p.get("HostName") or "").lower()
    dn = (p.get("DNSName") or "").lower()
    if hn == name or dn.startswith(name + "."):
        ips = [i for i in p.get("TailscaleIPs", []) if "." in i]
        print("online" if p.get("Online") else "offline", ips[0] if ips else "")
        break
' "$1" 2>/dev/null || true
}

# ---------- VPS ----------
cmd_vps() {
  local name="vps" peer="internal" user="" alias="internal" timeout=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --peer) peer="$2"; shift 2;;
      --user) user="$2"; shift 2;;
      --alias) alias="$2"; shift 2;;
      --timeout) timeout="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *) die "未知参数: $1";;
    esac
  done
  if [[ -z "$user" ]]; then
    if [[ -t 0 ]]; then read -r -p "内部服务器上的登录用户名 [$USER]: " user; fi
    user="${user:-$USER}"
  fi

  require_root
  need_basics
  install_tailscale
  tailscale_login "$name"

  # 专用密钥(只用于连内部服务器)
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  local key="$HOME/.ssh/$KEY_NAME"
  if [[ ! -f "$key" ]]; then
    log "生成专用 SSH 密钥 $key"
    ssh-keygen -q -t ed25519 -N "" -C "tailnet-bridge@$(hostname)" -f "$key"
  fi
  local pub; pub="$(cat "$key.pub")"

  cat <<EOF

================ 下一步:在【内部服务器】上执行 ================
  git clone <本仓库地址> && cd tailnet-bridge
  ./setup.sh internal --name $peer
==============================================================
公钥会自动通过 Tailscale 文件传输(Taildrop)发给内部服务器。
若自动传输不可用,可手动: ./setup.sh internal --name $peer --pubkey '$pub'

EOF
  log "等待内部服务器 \"$peer\" 加入 tailnet 并可 SSH 登录(用户 $user)... Ctrl-C 可中止,重跑本命令即可继续"

  local sendf; sendf="$(mktemp -d)/tnb-$name.pub"; cp "$key.pub" "$sendf"
  local start=$SECONDS ip="" state="" last="" msg err serr tick=0 asked=0 ans
  while :; do
    read -r state ip <<<"$(peer_info "$peer")" || true
    if [[ -z "${state:-}" ]]; then
      msg="⏳ $peer 尚未出现在 tailnet 中"
    elif [[ "$state" != "online" || -z "${ip:-}" ]]; then
      msg="⏳ $peer 已注册但离线"
    else
      if err="$(ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
                    -o StrictHostKeyChecking=accept-new -o ControlPath=none \
                    "$user@$ip" true 2>&1)"; then
        break
      fi
      msg="⏳ $peer 在线($ip),SSH 尚不可用: $(tail -1 <<<"$err")"
      # 每约 15 秒通过 Taildrop 发一次公钥(内部服务器收到后会自动授权)
      if (( tick++ % 3 == 0 )); then
        if serr="$(ts file cp "$sendf" "$peer:" 2>&1)"; then
          msg="$msg(已通过 Taildrop 发送公钥)"
        else
          msg="$msg(Taildrop 发送失败: $(tail -1 <<<"$serr"))"
        fi
      fi
      # Taildrop 不可用且服务器允许密码登录时,交互式用密码一次性写入公钥
      if (( asked == 0 )) && [[ -t 0 && -n "${serr:-}" && "$err" == *"Permission denied"* && "$err" == *password* ]]; then
        asked=1
        log "$msg"; last="$msg"
        read -r -p "Taildrop 不可用。用 $user@$ip 的登录密码把公钥写入内部服务器? [Y/n] " ans
        if [[ "${ans:-Y}" =~ ^[Yy] ]]; then
          push_key_with_password "$user" "$ip" "$key" || warn "密码写入失败,稍后重试或在内部服务器用 --pubkey 手动授权"
        fi
      fi
    fi
    [[ "$msg" != "$last" ]] && { log "$msg"; last="$msg"; }
    if (( timeout > 0 && SECONDS - start > timeout )); then die "等待超时($timeout 秒)"; fi
    sleep 5
  done
  log "✅ 内部服务器已连通: $user@$ip"

  write_ssh_config "$alias" "$ip" "$user" "$key"

  cat <<EOF

完成。在 VPS 上:
  ssh $alias                                  # 登录内部服务器
  ssh -t $alias 'tmux new -As cc'             # 进入 tmux,在里面运行 claude
  ssh -J $alias 用户@虚拟机内网IP              # 经内部服务器跳到 qemu 虚拟机
EOF
}

# 生成在内部服务器上执行的"幂等写入 authorized_keys"命令
authorize_remote_cmd() {
  local pubfile="$1" blob line
  blob="$(awk '{print $2}' "$pubfile")"
  line="from=\"127.0.0.1,::1,$TAILNET_FROM\" $(cat "$pubfile")"
  printf "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; grep -qF '%s' ~/.ssh/authorized_keys || printf '%%s\\n' '%s' >> ~/.ssh/authorized_keys" "$blob" "$line"
}

push_key_with_password() {
  local user="$1" ip="$2" key="$3"
  ssh -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
      -o StrictHostKeyChecking=accept-new -o ControlPath=none \
      "$user@$ip" "$(authorize_remote_cmd "$key.pub")"
}

write_ssh_config() {
  local alias="$1" ip="$2" user="$3" key="$4"
  local cfg="$HOME/.ssh/config" begin="# >>> tailnet-bridge $1 >>>" end="# <<< tailnet-bridge $1 <<<"
  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  touch "$cfg" && chmod 600 "$cfg"
  python3 - "$cfg" "$begin" "$end" <<'PY'
import sys
cfg, begin, end = sys.argv[1:4]
out, skip = [], False
for line in open(cfg).read().splitlines():
    if line.strip() == begin: skip = True; continue
    if line.strip() == end: skip = False; continue
    if not skip: out.append(line)
open(cfg, "w").write("\n".join(out).rstrip("\n") + ("\n" if out else ""))
PY
  cat >>"$cfg" <<EOF

$begin
Host $alias
    HostName $ip
    User $user
    IdentityFile $key
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 6
    ControlMaster auto
    ControlPath ~/.ssh/cm-%C
    ControlPersist 10m
$end
EOF
  log "已写入 ~/.ssh/config (Host $alias)"
}

# ---------- 内部服务器 ----------
cmd_internal() {
  local name="internal" pubkey="" user="" key_timeout=1800
  ROOTLESS=1   # 默认无 root
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --pubkey) pubkey="$2"; shift 2;;
      --user) user="$2"; shift 2;;
      --key-timeout) key_timeout="$2"; shift 2;;
      --system) ROOTLESS=0; shift;;
      --rootless) ROOTLESS=1; shift;;   # 兼容旧参数(现为默认)
      -h|--help) usage; exit 0;;
      *) die "未知参数: $1";;
    esac
  done
  if (( ROOTLESS )); then
    SUDO=""   # 无 root 模式绝不调用 sudo
    user="$(id -un)"
  else
    require_root
    user="${user:-${SUDO_USER:-$(id -un)}}"
    [[ "$user" == "root" ]] && warn "将为 root 用户授权密钥;建议改用普通用户运行或指定 --user"
  fi
  id "$user" >/dev/null 2>&1 || die "用户不存在: $user"

  need_basics
  if (( ROOTLESS )); then rootless_start_tailscaled; else install_tailscale; fi
  tailscale_login "$name"

  local from="$TAILNET_FROM"
  if (( ROOTLESS )); then
    rootless_expose_ssh
    from="127.0.0.1,::1"   # serve 转发到本机,sshd 看到的来源是回环地址
    command -v tmux >/dev/null || warn "未找到 tmux(无法替你安装),请让管理员安装,或改用 screen"
  else
    ensure_sshd
    command -v tmux >/dev/null || { log "安装 tmux"; pkg_install tmux || warn "tmux 安装失败,请手动安装"; }
  fi

  if [[ -z "$pubkey" ]]; then
    pubkey="$(receive_pubkey "$key_timeout")" || true
  fi
  if [[ -n "$pubkey" ]]; then
    authorize_key "$user" "$pubkey" "$from"
  else
    warn "未收到公钥,VPS 将无法免密登录。可重跑本命令,或手动: ./setup.sh internal $( ((ROOTLESS)) || echo "--system ")--pubkey '...'"
  fi

  local ip; ip="$(ts ip -4 2>/dev/null | head -1 || true)"
  cat <<EOF

完成。本机 tailnet 地址: ${ip:-?}  主机名: $name  用户: $user$( ((ROOTLESS)) && echo '  (无 root / userspace 模式)')
- 未开放任何公网入站端口;SSH 公钥仅允许来自 $( ((ROOTLESS)) && echo 'tailnet 转发(本机回环)' || echo 'tailnet(100.64.0.0/10)')的连接。
- 回到 VPS,等待脚本提示 "内部服务器已连通"。
EOF
}

ensure_sshd() {
  if ! command -v sshd >/dev/null && [[ ! -x /usr/sbin/sshd ]]; then
    log "安装 openssh-server"
    if command -v apt-get >/dev/null; then pkg_install openssh-server; else pkg_install openssh-server || pkg_install openssh; fi
  fi
  if command -v systemctl >/dev/null; then
    $SUDO systemctl enable --now ssh  >/dev/null 2>&1 \
      || $SUDO systemctl enable --now sshd >/dev/null 2>&1 \
      || warn "无法通过 systemctl 启动 sshd,请手动确认 sshd 在运行"
  fi
}

authorize_key() {
  local user="$1" key="$2" from="${3:-$TAILNET_FROM}" home dir file blob
  [[ "$key" =~ ^(ssh-|ecdsa-|sk-) ]] || die "公钥格式不正确"
  home="$(getent passwd "$user" | cut -d: -f6)"
  dir="$home/.ssh"; file="$dir/authorized_keys"
  blob="$(awk '{print $2}' <<<"$key")"
  $SUDO install -d -m 700 -o "$user" "$dir"
  $SUDO touch "$file"
  # 先去掉同一把密钥的旧行再写入,保证重复运行只留一行且来源限制是最新的
  { $SUDO grep -vF -- "$blob" "$file" || true; printf 'from="%s" %s\n' "$from" "$key"; } | $SUDO tee "$file.tnb" >/dev/null
  $SUDO mv "$file.tnb" "$file"
  $SUDO chown "$user" "$file"; $SUDO chmod 600 "$file"
  log "已授权公钥(来源限制: $from)→ $file"
}

# 通过 Taildrop 等待 VPS 发来的公钥(文件名 tnb-*.pub);成功时在 stdout 输出公钥
receive_pubkey() {
  local secs="$1" dir f key start=$SECONDS
  dir="$(mktemp -d)"
  log "等待 VPS 通过 Taildrop 发来公钥(最多 ${secs}s;Ctrl-C 后可改用 --pubkey 手动提供)..." >&2
  while (( SECONDS - start < secs )); do
    ts file get --conflict=overwrite "$dir" >/dev/null 2>&1 || true
    for f in "$dir"/tnb-*.pub; do
      [[ -f "$f" ]] || continue
      (( $(wc -c <"$f") < 2048 )) || continue
      key="$(head -1 "$f")"
      if [[ "$key" =~ ^(ssh-|ecdsa-|sk-) ]]; then
        log "已收到公钥 ($(basename "$f"))" >&2
        printf '%s\n' "$key"; rm -rf "$dir"; return 0
      fi
    done
    sleep 3
  done
  rm -rf "$dir"; return 1
}

# ---------- rootless(无 root/sudo) ----------
# 以后台服务运行: 优先 systemd --user,否则 nohup
rl_run_service() {
  local name="$1"; shift
  local cmd="$*"
  if systemctl --user show-environment >/dev/null 2>&1; then
    local d="$HOME/.config/systemd/user"; mkdir -p "$d"
    cat >"$d/tnb-$name.service" <<EOF
[Unit]
Description=tailnet-bridge $name
[Service]
ExecStart=$cmd
Restart=always
RestartSec=3
[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "tnb-$name.service" >/dev/null 2>&1 || true
    systemctl --user restart "tnb-$name.service"
    if ! loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q yes; then
      loginctl enable-linger "$(id -un)" 2>/dev/null \
        || warn "无法启用 linger:你退出登录后服务可能停止,需管理员执行 'loginctl enable-linger $(id -un)'"
    fi
  else
    warn "systemd --user 不可用,改用 nohup 后台进程(机器重启后需重新运行本脚本)"
    local pidf="$RL_DIR/$name.pid"
    if [[ -f "$pidf" ]] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
      kill "$(cat "$pidf")" 2>/dev/null || true; sleep 1
    fi
    setsid nohup bash -c "exec $cmd" >"$RL_DIR/$name.log" 2>&1 </dev/null &
    echo $! >"$pidf"
  fi
}

rootless_install_tailscale() {
  [[ -x "$RL_DIR/bin/tailscaled" && -x "$RL_DIR/bin/tailscale" ]] && return 0
  local arch meta file tmp
  case "$(uname -m)" in
    x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; armv6l|armv7l) arch=arm;; i?86) arch=386;;
    *) die "不支持的架构: $(uname -m)";;
  esac
  log "下载 tailscale 静态二进制 ($arch) ..."
  meta="$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json')" || die "无法获取 tailscale 版本信息"
  file="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Tarballs"][sys.argv[1]])' "$arch" <<<"$meta")" \
    || die "找不到适用于 $arch 的 tailscale 压缩包"
  tmp="$(mktemp -d)"
  curl -fsSL "https://pkgs.tailscale.com/stable/$file" -o "$tmp/ts.tgz" || die "下载失败"
  mkdir "$tmp/x" && tar -xzf "$tmp/ts.tgz" --strip-components=1 -C "$tmp/x"
  install -m 755 "$tmp/x/tailscale" "$tmp/x/tailscaled" "$RL_DIR/bin/"
  rm -rf "$tmp"
}

rootless_start_tailscaled() {
  mkdir -p "$RL_DIR/bin" && chmod 700 "$RL_DIR"
  rootless_install_tailscale
  log "启动 tailscaled(userspace 网络模式,无需 root)"
  rl_run_service tailscaled "$RL_DIR/bin/tailscaled --tun=userspace-networking --statedir=$RL_DIR --state=$RL_DIR/tailscaled.state --socket=$RL_SOCK"
  local i
  for i in $(seq 1 20); do
    [[ -n "$(backend_state)" ]] && return 0
    sleep 1
  done
  die "tailscaled 未就绪,查看 $RL_DIR/tailscaled.log 或 journalctl --user -u tnb-tailscaled"
}

# 无 root 时自己跑一个仅监听 127.0.0.1 的用户态 sshd
rootless_start_sshd() {
  local port="$1" sshd d="$RL_DIR/ssh"
  sshd="$(command -v sshd || true)"
  if [[ -z "$sshd" && -x /usr/sbin/sshd ]]; then sshd=/usr/sbin/sshd; fi
  [[ -n "$sshd" ]] || die "本机没有 sshd 可用,请让管理员安装 openssh-server"
  mkdir -p "$d" && chmod 700 "$d"
  [[ -f "$d/hostkey" ]] || ssh-keygen -q -t ed25519 -N "" -f "$d/hostkey"
  cat >"$d/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $d/hostkey
PidFile $d/sshd.pid
AuthorizedKeysFile $HOME/.ssh/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
EOF
  "$sshd" -t -f "$d/sshd_config" || die "sshd 配置检查失败"
  log "启动用户态 sshd (127.0.0.1:$port)"
  rl_run_service sshd "$sshd -D -e -f $d/sshd_config"
}

# 让 tailnet:22 指向本机 sshd(系统 sshd 优先,没有则用用户态 sshd)
rootless_expose_ssh() {
  local port=22
  if (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
    log "检测到本机 sshd 监听 22,直接转发"
  else
    port=2222
    rootless_start_sshd "$port"
  fi
  log "tailscale serve: tailnet:22 → localhost:$port"
  ts serve --bg --tcp=22 "tcp://localhost:$port" >/dev/null 2>&1 \
    || ts serve --bg tcp:22 "tcp://localhost:$port" >/dev/null 2>&1 \
    || die "tailscale serve 失败(需要较新的 tailscale);可手动运行: tailscale serve --bg --tcp=22 tcp://localhost:$port"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  local sub="$1"; shift
  case "$sub" in
    vps) cmd_vps "$@";;
    internal) cmd_internal "$@";;
    -h|--help|help) usage;;
    *) usage; exit 1;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
