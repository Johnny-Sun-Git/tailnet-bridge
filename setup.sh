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

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  command -v sudo >/dev/null || die "需要 root 或 sudo"
  SUDO="sudo"
fi

ts() { $SUDO tailscale "$@"; }

usage() {
  cat <<'EOF'
用法:
  ./setup.sh vps      [--name vps] [--peer internal] [--user 用户名] [--alias internal] [--timeout 秒]
  ./setup.sh internal [--name internal] [--pubkey 'ssh-ed25519 ...'] [--user 用户名]

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
  command -v curl    >/dev/null || pkg_install curl
  command -v python3 >/dev/null || pkg_install python3
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
  ./setup.sh internal --name $peer --pubkey '$pub'
==============================================================

EOF
  log "等待内部服务器 \"$peer\" 加入 tailnet 并可 SSH 登录(用户 $user)... Ctrl-C 可中止,重跑本命令即可继续"

  local start=$SECONDS ip="" state="" last="" msg err
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
  local name="internal" pubkey="" user=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) name="$2"; shift 2;;
      --pubkey) pubkey="$2"; shift 2;;
      --user) user="$2"; shift 2;;
      -h|--help) usage; exit 0;;
      *) die "未知参数: $1";;
    esac
  done
  user="${user:-${SUDO_USER:-$(id -un)}}"
  [[ "$user" == "root" ]] && warn "将为 root 用户授权密钥;建议改用普通用户运行或指定 --user"
  id "$user" >/dev/null 2>&1 || die "用户不存在: $user"

  need_basics
  install_tailscale
  tailscale_login "$name"

  ensure_sshd
  command -v tmux >/dev/null || { log "安装 tmux"; pkg_install tmux || warn "tmux 安装失败,请手动安装"; }

  if [[ -z "$pubkey" && -t 0 ]]; then
    read -r -p "粘贴 VPS 脚本打印的公钥(留空跳过): " pubkey
  fi
  if [[ -n "$pubkey" ]]; then
    authorize_key "$user" "$pubkey"
  else
    warn "未提供公钥,VPS 将无法免密登录。可稍后重跑: ./setup.sh internal --pubkey '...'"
  fi

  local ip; ip="$(ts ip -4 2>/dev/null | head -1 || true)"
  cat <<EOF

完成。本机 tailnet 地址: ${ip:-?}  主机名: $name  用户: $user
- 未开放任何公网入站端口;SSH 公钥仅允许来自 tailnet(100.64.0.0/10)的连接。
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
  local user="$1" key="$2" home dir file blob
  [[ "$key" =~ ^(ssh-|ecdsa-|sk-) ]] || die "公钥格式不正确"
  home="$(getent passwd "$user" | cut -d: -f6)"
  dir="$home/.ssh"; file="$dir/authorized_keys"
  blob="$(awk '{print $2}' <<<"$key")"
  $SUDO install -d -m 700 -o "$user" "$dir"
  $SUDO touch "$file"
  if $SUDO grep -qF "$blob" "$file"; then
    log "公钥已存在于 $file"
  else
    printf 'from="%s" %s\n' "$TAILNET_FROM" "$key" | $SUDO tee -a "$file" >/dev/null
    log "已授权公钥(仅限 tailnet 来源)→ $file"
  fi
  $SUDO chown "$user" "$file"; $SUDO chmod 600 "$file"
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
