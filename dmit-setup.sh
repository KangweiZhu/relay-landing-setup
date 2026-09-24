#!/usr/bin/env bash
# ============================================================================
#  DMIT Relay —— Reality / Hysteria2 节点 + 新泽西中转，一键部署与管理
#
#  线路 1  国内 ─Reality─> DMIT                    出口 DMIT
#  线路 2  国内 ─Hy2─────> DMIT                    出口 DMIT
#  线路 3  国内 ─Reality─> DMIT ─SS2022─> 新泽西    出口家宽
#  线路 4  国内 ─Hy2─────────────────────> 新泽西   家里现有的 Hy2，本脚本不碰
#
#  ./dmit-setup.sh            打开菜单（未安装时自动安装）
#  ./dmit-setup.sh <编号>     直接执行菜单里对应的功能，如 ./dmit-setup.sh 3
#  ./dmit-setup.sh help       查看全部编号和命令
#  安装后 dmit 等同于 ./dmit-setup.sh
# ============================================================================
set -euo pipefail

STATE_DIR=/etc/dmit-relay
SECRETS=$STATE_DIR/secrets.env
SB_DIR=/etc/sing-box
SB_BIN=/usr/local/bin/sing-box
SELF=/usr/local/bin/dmit
LINKS=/root/client-links.txt
NJ_SCRIPT=/root/nj-setup.sh
PROXY_PORT=${PROXY_PORT:-443}
DEFAULT_SNI=www.microsoft.com
DEFAULT_NJ_HOST=ddns.kz7.site
DEFAULT_NJ_PORT=40553
DEFAULT_NJ_SSH_USER=root
DEFAULT_NJ_SSH_PORT=40550
MENU_MODE=0
TIME_FIX_HINT="./dmit-setup.sh time"

# ============================================================================ 样式
if [[ -t 1 ]]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' BL=$'\e[34m' M=$'\e[35m' C=$'\e[36m' N=$'\e[0m'
else
  B='' D='' R='' G='' Y='' BL='' M='' C='' N=''
fi
hr()      { printf '%s\n' "${D}──────────────────────────────────────────────────────────────${N}"; }
banner()  { echo; printf '  %s  %s\n' "${C}${B}▌ DMIT Relay${N}" "${D}Reality · Hysteria2 · 新泽西中转${N}"; hr; }
section() { echo; printf '%s\n' "${B}${BL}▸ $*${N}"; }
step()    { echo; printf '%s %s\n' "${C}${B}[$1/$2]${N}" "${B}$3${N}"; }
ok()      { printf '  %s %s\n' "${G}✔${N}" "$*"; }
warn()    { printf '  %s %s\n' "${Y}!${N}" "$*"; }
fail()    { printf '  %s %s\n' "${R}✘${N}" "$*"; }
info()    { printf '  %s\n' "${D}$*${N}"; }
die()     { echo; printf '%s\n' "${R}${B}✘ 错误：${N}$*" >&2; exit 1; }
kv()      { printf '  %s  %s\n' "${D}$1${N}" "$2"; }
ask() {   # ask 变量名 提示 默认值
  local __v; read -rp "  ${M}?${N} $2 ${D}[$3]${N}: " __v
  printf -v "$1" '%s' "${__v:-$3}"
}
confirm() {  # confirm 提示 [默认 y|n]
  local d=${2:-n} a hint='[y/N]'; [[ $d == y ]] && hint='[Y/n]'
  read -rp "  ${Y}?${N} $1 ${D}${hint}${N}: " a; a=${a:-$d}; [[ ${a,,} == y ]]
}

# ============================================================================ 基础
need_root()      { [[ $EUID -eq 0 ]] || die "请用 root 运行"; }
need_installed() { [[ -f $SB_DIR/config.json && -f $SECRETS ]] || die "还没安装，先运行：./dmit-setup.sh install"; }
load()   { [[ -f $SECRETS ]] && source "$SECRETS"; return 0; }
save()   { sed -i "/^$1=/d" "$SECRETS"; printf '%s=%q\n' "$1" "$2" >>"$SECRETS"; }
unsave() { sed -i "/^$1=/d" "$SECRETS"; }
sb_ver() { "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}'; }
nj_on()  { [[ -n ${NJ_HOST:-} ]]; }
on1()    { [[ ${LINE1_ON:-1} == 1 ]]; }
on2()    { [[ ${LINE2_ON:-1} == 1 ]]; }
on3()    { nj_on && [[ ${LINE3_ON:-1} == 1 ]]; }
ssh_user() { echo "${NJ_SSH_USER:-$DEFAULT_NJ_SSH_USER}"; }
ssh_port() { echo "${NJ_SSH_PORT:-$DEFAULT_NJ_SSH_PORT}"; }
remote_run() { [[ $(ssh_user) == root ]] && echo "bash ~/nj-setup.sh" || echo "sudo bash ~/nj-setup.sh"; }
badge()  {
  case $1 in
    3) if ! nj_on; then echo "${D}○ 未配置${N}"; elif on3; then echo "${G}● 开${N}"; else echo "${R}○ 关${N}"; fi ;;
    *) if on"$1"; then echo "${G}● 开${N}"; else echo "${R}○ 关${N}"; fi ;;
  esac
}
install_self() {
  local src; src=$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || true)
  if [[ -f $src && $src != "$SELF" ]]; then install -m 755 "$src" "$SELF"; fi
}
tcp_ok() { timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

# ============================================================================ 两端共用
# 下面这些函数原样嵌进家里的 nj-setup.sh（declare -f），保证两端行为一致
SHARED_FUNCS=(apt_need has_timesvc base_deps https_date time_offset synced fix_time time_report)

apt_need() {  # apt_need 包...：只装缺的
  command -v apt-get >/dev/null || { fail "仅支持 Debian / Ubuntu（apt）"; exit 1; }
  local p miss=()
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || miss+=("$p")
  done
  if ((${#miss[@]} == 0)); then ok "依赖齐全"; return 0; fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${miss[@]}" >/dev/null
  ok "已补装：${miss[*]}"
}

has_timesvc() {  # 先存下输出再 grep，避免 pipefail 下 grep -q 提前退出造成误判
  local u; u=$(systemctl list-unit-files 2>/dev/null || true)
  grep -qE '^(systemd-timesyncd|chrony|chronyd|ntp|ntpsec)\.service' <<<"$u"
}

base_deps() {  # base_deps [额外的包...]：两端都要的依赖 + 额外的
  local pk=(curl ca-certificates tar iproute2)
  has_timesvc || pk+=(systemd-timesyncd)   # 已有 chrony / ntp 时不装，避免互相顶掉
  apt_need "${pk[@]}" "$@"
}

https_date() { curl -sI --max-time 5 https://www.google.com 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r'; }

time_offset() {  # 与 HTTPS 时间的偏差（秒，本机减标准）
  local h r; h=$(https_date); [[ -n $h ]] || return 1
  r=$(date -d "$h" +%s 2>/dev/null) || return 1
  echo $(( $(date +%s) - r ))
}

synced() { [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; }

fix_time() {  # 开 NTP → 偏差 > 3 秒立即校正 → NTP 不通则启用 HTTPS 校时兜底
  local ts_dir=/usr/local/lib/dmit-relay
  timedatectl set-ntp true 2>/dev/null || true

  local off; off=$(time_offset || true)
  if [[ -n $off ]] && (( ${off#-} > 3 )); then
    if date -s "$(https_date)" >/dev/null 2>&1; then ok "时间偏差 ${off} 秒，已立即校正"
    else fail "无法修改系统时间（容器环境？需要在宿主机上开启对时）"; fi
  elif [[ -n $off ]]; then
    ok "当前时间偏差 ${off} 秒"
  else
    warn "无法获取标准时间（连不上 www.google.com）"
  fi

  local i; for i in $(seq 1 10); do synced && break; sleep 2; done
  if synced; then
    ok "NTP 已同步"
    systemctl disable --now dmit-timesync.timer >/dev/null 2>&1 || true
  else
    warn "NTP 未能同步（可能 UDP 123 被挡），启用 HTTPS 校时兜底：每 10 分钟一次"
    mkdir -p "$ts_dir"
    cat >"$ts_dir/https-timesync.sh" <<'EOT'
#!/bin/sh
h=$(curl -sI --max-time 5 https://www.google.com | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
[ -n "$h" ] && date -s "$h" >/dev/null
EOT
    chmod 755 "$ts_dir/https-timesync.sh"
    cat >/etc/systemd/system/dmit-timesync.service <<EOT
[Unit]
Description=HTTPS time sync fallback for DMIT relay
[Service]
Type=oneshot
ExecStart=$ts_dir/https-timesync.sh
EOT
    cat >/etc/systemd/system/dmit-timesync.timer <<'EOT'
[Unit]
Description=Run HTTPS time sync every 10 minutes
[Timer]
OnBootSec=30s
OnUnitActiveSec=10min
[Install]
WantedBy=timers.target
EOT
    systemctl daemon-reload
    systemctl enable --now dmit-timesync.timer >/dev/null 2>&1
    ok "HTTPS 校时已启用"
  fi
}

time_report() {  # 状态里的时间部分；TIME_FIX_HINT 由各端自己定义
  local off; off=$(time_offset || true)
  if synced; then ok "NTP 已同步"
  elif systemctl is-active --quiet dmit-timesync.timer 2>/dev/null; then ok "HTTPS 校时兜底运行中"
  else warn "NTP 未同步 → $TIME_FIX_HINT"; fi
  if [[ -z $off ]]; then warn "无法获取标准时间"
  elif (( ${off#-} > 30 )); then fail "时间偏差 ${off} 秒，超过 30 秒，线路 3 会被拒绝 → $TIME_FIX_HINT"
  else ok "时间偏差 ${off} 秒"; fi
}

install_singbox() {
  local arch latest cur tmp
  case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "不支持的架构: $(uname -m)" ;;
  esac
  latest=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/^v//')
  [[ -n $latest && $latest != null ]] || die "获取 sing-box 最新版本失败（GitHub API 可能限流，稍后再试）"
  cur=$(sb_ver || true)
  if [[ $cur == "$latest" ]]; then ok "sing-box 已是最新版 v$cur"; return; fi
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/sb.tgz" \
    "https://github.com/SagerNet/sing-box/releases/download/v${latest}/sing-box-${latest}-linux-${arch}.tar.gz"
  tar -xzf "$tmp/sb.tgz" -C "$tmp"
  install -m 755 "$tmp/sing-box-${latest}-linux-${arch}/sing-box" "$SB_BIN"
  rm -rf "$tmp"
  ok "sing-box ${cur:+v$cur → }v$latest"
}

check_sni() {
  local out
  out=$(echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -groups X25519 2>/dev/null || true)
  if grep -q "TLSv1.3" <<<"$out"; then ok "伪装站点 $1 支持 TLS1.3 + X25519"
  else warn "伪装站点 $1 似乎不支持 TLS1.3 + X25519，建议换一个"; fi
}

detect_ip() {
  local ip
  ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  [[ -n $ip ]] || ip=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  [[ -n $ip ]] || die "获取本机公网 IPv4 失败"
  save PUB_IP "$ip"; PUB_IP=$ip
  ok "本机公网 IPv4：$ip"
}

enable_bbr() {
  cat >/etc/sysctl.d/99-dmit-relay.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  ok "BBR 已开启（当前：$(sysctl -n net.ipv4.tcp_congestion_control)）"
}

# ============================================================================ 密钥
init_secrets() {
  mkdir -p "$STATE_DIR" "$SB_DIR"; chmod 700 "$STATE_DIR"
  touch "$SECRETS"; chmod 600 "$SECRETS"
  load
  if [[ -n ${UUID:-} ]]; then ok "沿用已有密钥（伪装站点 $SNI）"; return; fi
  info "伪装站点要求：国内能直接访问、支持 TLS1.3"
  ask SNI "Reality 伪装站点" "$DEFAULT_SNI"
  local kp; kp=$("$SB_BIN" generate reality-keypair)
  save SNI "$SNI"
  save UUID "$("$SB_BIN" generate uuid)"
  save REALITY_PRIV "$(awk '/PrivateKey/{print $2}' <<<"$kp")"
  save REALITY_PUB "$(awk '/PublicKey/{print $2}' <<<"$kp")"
  save SHORT_ID "$("$SB_BIN" generate rand 8 --hex)"
  save HY2_PASS "$("$SB_BIN" generate rand 16 --hex)"
  save HY2_OBFS "$("$SB_BIN" generate rand 16 --hex)"
  load
  ok "已生成线路 1 / 2 的密钥"
}

nj_keys() {
  [[ -n ${NJ_SS_KEY:-} ]] || save NJ_SS_KEY "$("$SB_BIN" generate rand 16 --base64)"
  [[ -n ${UUID_NJ:-} ]]   || save UUID_NJ "$("$SB_BIN" generate uuid)"
  load
}

nj_prompt() {  # nj_prompt [force]
  load
  if nj_on && [[ ${1:-} != force ]]; then nj_keys; ok "沿用线路 3 配置（$NJ_HOST:$NJ_PORT）"; return; fi
  info "线路 3：DMIT 用 Shadowsocks-2022 连新泽西，和家里的 Hy2 完全无关"
  if [[ ${1:-} != force ]] && ! confirm "现在配置线路 3 吗" y; then
    warn "跳过线路 3，之后可用 ./dmit-setup.sh 9 补上"; return
  fi
  ask NJ_HOST     "家里 DDNS 域名"                         "${NJ_HOST:-$DEFAULT_NJ_HOST}"
  ask NJ_PORT     "家里中转端口（路由器需转发 TCP+UDP）"   "${NJ_PORT:-$DEFAULT_NJ_PORT}"
  ask NJ_SSH_USER "家里 SSH 用户名（一键部署用）"          "$(ssh_user)"
  ask NJ_SSH_PORT "家里 SSH 端口"                          "$(ssh_port)"
  save NJ_HOST "$NJ_HOST"; save NJ_PORT "$NJ_PORT"; save LINE3_ON 1
  save NJ_SSH_USER "$NJ_SSH_USER"; save NJ_SSH_PORT "$NJ_SSH_PORT"
  nj_keys
  ok "线路 3 → $NJ_HOST:$NJ_PORT ${D}（SSH $(ssh_user)@$NJ_HOST:$(ssh_port)）${N}"
}

# ============================================================================ 配置
join() { local IFS=$'\x1f'; local s="$*"; printf '%s' "${s//$'\x1f'/,$'\n'}"; }

write_config() {
  load
  if [[ ! -f $SB_DIR/hy2.crt ]]; then
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
      -subj "/CN=${SNI}" -keyout "$SB_DIR/hy2.key" -out "$SB_DIR/hy2.crt" 2>/dev/null
    chmod 600 "$SB_DIR/hy2.key"
  fi

  local users=() inbounds=() outbounds=() rules="[]"
  on1 && users+=("{ \"name\": \"dmit\", \"uuid\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\" }")
  on3 && users+=("{ \"name\": \"nj\", \"uuid\": \"${UUID_NJ}\", \"flow\": \"xtls-rprx-vision\" }")

  if ((${#users[@]})); then
    inbounds+=("    {
      \"type\": \"vless\",
      \"tag\": \"reality-in\",
      \"listen\": \"::\",
      \"listen_port\": ${PROXY_PORT},
      \"users\": [ $(IFS=,; echo "${users[*]}") ],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${SNI}\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": { \"server\": \"${SNI}\", \"server_port\": 443 },
          \"private_key\": \"${REALITY_PRIV}\",
          \"short_id\": [ \"${SHORT_ID}\" ]
        }
      }
    }")
  fi
  if on2; then
    inbounds+=("    {
      \"type\": \"hysteria2\",
      \"tag\": \"hy2-in\",
      \"listen\": \"::\",
      \"listen_port\": ${PROXY_PORT},
      \"users\": [ { \"password\": \"${HY2_PASS}\" } ],
      \"obfs\": { \"type\": \"salamander\", \"password\": \"${HY2_OBFS}\" },
      \"tls\": {
        \"enabled\": true,
        \"alpn\": [ \"h3\" ],
        \"certificate_path\": \"${SB_DIR}/hy2.crt\",
        \"key_path\": \"${SB_DIR}/hy2.key\"
      }
    }")
  fi

  outbounds+=('    { "type": "direct", "tag": "direct" }')
  if on3; then
    outbounds+=("    {
      \"type\": \"shadowsocks\",
      \"tag\": \"to-nj\",
      \"server\": \"${NJ_HOST}\",
      \"server_port\": ${NJ_PORT},
      \"method\": \"2022-blake3-aes-128-gcm\",
      \"password\": \"${NJ_SS_KEY}\"
    }")
    rules='[ { "auth_user": [ "nj" ], "outbound": "to-nj" } ]'
  fi

  cat >"$SB_DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": { "servers": [ { "type": "local", "tag": "local" } ] },
  "inbounds": [
$( ((${#inbounds[@]})) && join "${inbounds[@]}" )
  ],
  "outbounds": [
$(join "${outbounds[@]}")
  ],
  "route": {
    "rules": ${rules},
    "final": "direct",
    "default_domain_resolver": "local"
  }
}
EOF
  chmod 600 "$SB_DIR/config.json"
  "$SB_BIN" check -c "$SB_DIR/config.json" || die "sing-box 配置校验失败，把上面的报错发出来排查"
  ok "配置已生成并通过校验"
}

write_service() {
  cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box (DMIT Relay)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=${SB_BIN} run -c ${SB_DIR}/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable sing-box >/dev/null 2>&1
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${PROXY_PORT}/tcp" >/dev/null; ufw allow "${PROXY_PORT}/udp" >/dev/null
    ok "ufw 已放行 ${PROXY_PORT}/tcp + udp"
  fi
}

apply() {
  write_config
  if on1 || on2 || on3; then
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box; sleep 1
    if systemctl is-active --quiet sing-box; then ok "sing-box 运行中"
    else fail "sing-box 启动失败"; journalctl -u sing-box -n 20 --no-pager; exit 1; fi
  else
    systemctl disable --now sing-box >/dev/null 2>&1 || true
    warn "三条线路都已关闭，sing-box 已停止"
  fi
}

# ============================================================================ 家里中转端脚本
write_nj_script() {
  load; nj_on || { rm -f "$NJ_SCRIPT"; return 0; }
  umask 077
  {
    echo '#!/usr/bin/env bash'
    echo '# 新泽西家里的中转端（DMIT 线路 3 专用，独立的 Shadowsocks-2022 服务，不影响家里的 Hy2）'
    echo '#   sudo bash nj-setup.sh            安装 / 重装'
    echo '#   sudo bash nj-setup.sh status     状态：服务、端口、时间同步、公网 IP 与 DDNS'
    echo '#   sudo bash nj-setup.sh time       只修正时间同步'
    echo '#   sudo bash nj-setup.sh uninstall  卸载'
    printf 'NJ_HOST=%q\nNJ_PORT=%q\nNJ_SS_KEY=%q\nSB_VER=%q\n' "$NJ_HOST" "$NJ_PORT" "$NJ_SS_KEY" "$(sb_ver)"
    cat <<'NJEOF'
set -euo pipefail
DIR=/usr/local/lib/dmit-relay
if [[ -t 1 ]]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
else
  B='' D='' R='' G='' Y='' C='' N=''
fi
ok()      { printf '  %s %s\n' "${G}✔${N}" "$*"; }
warn()    { printf '  %s %s\n' "${Y}!${N}" "$*"; }
fail()    { printf '  %s %s\n' "${R}✘${N}" "$*"; }
kv()      { printf '  %s  %s\n' "${D}$1${N}" "$2"; }
section() { echo; printf '%s\n' "${B}${C}▸ $*${N}"; }
banner()  { echo; printf '  %s  %s\n' "${C}${B}▌ DMIT Relay · 家里中转端${N}" "${D}端口 ${NJ_PORT} · SS2022${N}"; printf '%s\n' "${D}──────────────────────────────────────────────────────────────${N}"; }
[[ $EUID -eq 0 ]] || { echo "请用 root 运行"; exit 1; }
TIME_FIX_HINT="sudo bash nj-setup.sh time"

# ---- 以下与 DMIT 端共用（由 dmit-setup.sh 原样嵌入）----
NJEOF
    declare -f "${SHARED_FUNCS[@]}"
    cat <<'NJEOF'
# ---- 共用部分结束 ----

do_time() {
  section "时间同步 ${D}（SS2022 要求两端误差 < 30 秒）${N}"
  base_deps
  fix_time
}

install_relay() {
  banner
  section "依赖"
  base_deps
  section "安装 sing-box"
  local A T
  case "$(uname -m)" in x86_64) A=amd64 ;; aarch64) A=arm64 ;; *) fail "不支持的架构"; exit 1 ;; esac
  mkdir -p "$DIR"; T=$(mktemp -d)
  curl -fsSL -o "$T/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/sing-box-${SB_VER}-linux-$A.tar.gz"
  tar -xzf "$T/sb.tgz" -C "$T"
  install -m 755 "$T/sing-box-${SB_VER}-linux-$A/sing-box" "$DIR/sing-box"; rm -rf "$T"
  ok "sing-box v${SB_VER}（装在 $DIR，不影响系统里其他 sing-box）"

  section "配置中转服务"
  cat >"$DIR/config.json" <<CONF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": { "servers": [ { "type": "local", "tag": "local" } ] },
  "inbounds": [ {
    "type": "shadowsocks", "tag": "ss-in", "listen": "::", "listen_port": ${NJ_PORT},
    "method": "2022-blake3-aes-128-gcm", "password": "${NJ_SS_KEY}"
  } ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ],
  "route": { "final": "direct", "default_domain_resolver": "local" }
}
CONF
  chmod 600 "$DIR/config.json"
  "$DIR/sing-box" check -c "$DIR/config.json"
  cat >/etc/systemd/system/dmit-relay.service <<UNIT
[Unit]
Description=sing-box relay endpoint for DMIT
After=network-online.target time-sync.target
Wants=network-online.target
[Service]
ExecStart=$DIR/sing-box run -c $DIR/config.json
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload; systemctl enable dmit-relay >/dev/null 2>&1; systemctl restart dmit-relay
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${NJ_PORT}/tcp" >/dev/null; ufw allow "${NJ_PORT}/udp" >/dev/null; ok "ufw 已放行 ${NJ_PORT}"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${NJ_PORT}/tcp" --add-port="${NJ_PORT}/udp" >/dev/null
    firewall-cmd --reload >/dev/null; ok "firewalld 已放行 ${NJ_PORT}"
  fi
  sleep 1
  if systemctl is-active --quiet dmit-relay; then ok "中转服务运行中"
  else fail "启动失败：journalctl -u dmit-relay -e"; exit 1; fi

  do_time
  status_relay nobanner
}

status_relay() {
  [[ ${1:-} == nobanner ]] || banner
  section "服务"
  systemctl is-active --quiet dmit-relay && ok "dmit-relay 运行中" || fail "dmit-relay 未运行 → journalctl -u dmit-relay -e"
  ss -Hlntp "sport = :${NJ_PORT}" 2>/dev/null | grep -q sing-box && ok "TCP ${NJ_PORT} 监听中" || fail "TCP ${NJ_PORT} 未监听"
  ss -Hlnup "sport = :${NJ_PORT}" 2>/dev/null | grep -q sing-box && ok "UDP ${NJ_PORT} 监听中" || fail "UDP ${NJ_PORT} 未监听"

  section "时间"
  time_report

  section "网络"
  local ip dns
  ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
  dns=$(getent ahostsv4 "$NJ_HOST" 2>/dev/null | awk '{print $1; exit}' || true)
  kv "公网 IP" "${ip:-获取失败}"
  kv "DDNS　 " "$NJ_HOST → ${dns:-解析失败}"
  if [[ -n $ip && $ip == "$dns" ]]; then ok "DDNS 指向正确"
  else warn "DDNS 与公网 IP 不一致（刚换 IP 的话等 DDNS 更新即可）"; fi
  echo
}

uninstall_relay() {
  systemctl disable --now dmit-relay dmit-timesync.timer >/dev/null 2>&1 || true
  rm -rf "$DIR" /etc/systemd/system/dmit-relay.service /etc/systemd/system/dmit-timesync.service /etc/systemd/system/dmit-timesync.timer
  systemctl daemon-reload
  ok "家里中转端已卸载（NTP 对时保留）"
}

case ${1:-install} in
  install)   install_relay ;;
  status)    status_relay ;;
  time)      do_time ;;
  uninstall) uninstall_relay ;;
  *)         echo "用法：sudo bash nj-setup.sh [install|status|time|uninstall]"; exit 1 ;;
esac
NJEOF
  } >"$NJ_SCRIPT"
  chmod 700 "$NJ_SCRIPT"
  umask 022
  ok "家里中转端脚本已生成：$NJ_SCRIPT"
}

# ============================================================================ 链接
build_links() {
  load
  [[ -n ${PUB_IP:-} ]] || detect_ip >/dev/null
  local r="encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=tcp"
  L1="" L2="" L3=""
  on1 && L1="vless://${UUID}@${PUB_IP}:${PROXY_PORT}?${r}#1-dmit-reality"
  on2 && L2="hysteria2://${HY2_PASS}@${PUB_IP}:${PROXY_PORT}?obfs=salamander&obfs-password=${HY2_OBFS}&sni=${SNI}&insecure=1#2-dmit-hy2"
  on3 && L3="vless://${UUID_NJ}@${PUB_IP}:${PROXY_PORT}?${r}#3-dmit-to-nj"
  umask 077; printf '%s\n' "$L1" "$L2" "$L3" | sed '/^$/d' >"$LINKS"; umask 022
}

link_block() {
  echo
  printf '  %s  %s  %s\n' "${C}${B}线路 $1  $2${N}" "${D}$3 ｜ 出口 $4${N}" "$(badge "$1")"
  if [[ -n $5 ]]; then printf '  %s\n' "${G}$5${N}"
  elif [[ $1 == 3 ]] && ! nj_on; then info "未配置 → ./dmit-setup.sh 9"
  else info "已关闭 → ./dmit-setup.sh $(( $1 + 4 )) 开启"; fi
}

show_links() {
  build_links
  section "客户端链接   ${D}（复制整行导入；原文在 $LINKS）${N}"
  link_block 1 "1-dmit-reality" "国内 → DMIT（Reality）"   "DMIT" "$L1"
  link_block 2 "2-dmit-hy2"     "国内 → DMIT（Hysteria2）" "DMIT" "$L2"
  link_block 3 "3-dmit-to-nj"   "国内 → DMIT → 新泽西"     "家宽" "$L3"
  echo; printf '  %s  %s\n' "${D}线路 4  家里 Hy2${N}" "${D}你现有的节点，不受本脚本影响${N}"
  echo
  info "线路 1 和 3 只差开头的 UUID；导入 Hy2 时确认混淆 salamander 和“跳过证书验证”都在"
}

show_qr() {
  build_links
  command -v qrencode >/dev/null || apt-get install -y -qq qrencode >/dev/null
  local name link any=0
  for pair in "线路 1 · 1-dmit-reality|$L1" "线路 2 · 2-dmit-hy2|$L2" "线路 3 · 3-dmit-to-nj|$L3"; do
    name=${pair%%|*}; link=${pair#*|}; [[ -n $link ]] || continue
    any=1; section "$name"; qrencode -t ansiutf8 -m 1 "$link"
  done
  ((any)) || warn "没有已开启的线路"
}

nj_hint() {
  load
  nj_on || { warn "线路 3 未配置，先运行 ./dmit-setup.sh 9"; return 0; }
  [[ -f $NJ_SCRIPT ]] || write_nj_script >/dev/null
  local t="$(ssh_user)@${NJ_HOST}"
  section "家里中转端：手动安装步骤 ${D}（或直接用 ./dmit-setup.sh 12 一键完成）${N}"
  kv "① 拷过去" "scp -P $(ssh_port) ${NJ_SCRIPT} ${t}:~/"
  kv "② 去安装" "ssh -t -p $(ssh_port) ${t} '$(remote_run)'"
  kv "③ 路由器" "端口 ${NJ_PORT} 同时转发 TCP 和 UDP 到那台机器"
  kv "④ 验证　" "./dmit-setup.sh 3（DMIT 这边）  ./dmit-setup.sh 13（家里那边）"
  echo
  info "家里脚本的其他用法：status 看状态 · time 修时间 · uninstall 卸载"
}

# ============================================================================ 功能
cmd_install() {
  need_root; banner
  local n=6
  step 1 $n "安装依赖";       base_deps jq openssl qrencode openssh-client
  step 2 $n "安装 sing-box";  install_singbox
  step 3 $n "密钥与参数";     init_secrets; nj_prompt; check_sni "$SNI"; detect_ip
  step 4 $n "系统优化与对时"; enable_bbr; fix_time
  step 5 $n "生成配置并启动"; write_service; apply; write_nj_script
  step 6 $n "安装管理命令";   install_self; ok "以后可以用 ${B}dmit${N} 代替 ./dmit-setup.sh"
  show_links
  load
  if nj_on; then
    echo
    if tcp_ok "$NJ_HOST" "$NJ_PORT"; then
      ok "家里中转端已在线（$NJ_HOST:$NJ_PORT）"
      info "如果家里用的是旧版中转端，建议用 ./dmit-setup.sh 12 更新一次（带自动补依赖和对时）"
    else
      warn "家里中转端还不可达 → ./dmit-setup.sh 12 一键部署"
    fi
  fi
  echo; hr
}

cmd_status() {
  need_root; need_installed; load
  section "服务"
  if systemctl is-active --quiet sing-box; then
    ok "sing-box 运行中 ${D}v$(sb_ver) · 已运行 $(ps -o etime= -p "$(systemctl show -p MainPID --value sing-box)" | xargs)${N}"
  else fail "sing-box 未运行 → ./dmit-setup.sh 4 看日志"; fi
  if on1 || on3; then
    ss -Hlntp "sport = :${PROXY_PORT}" 2>/dev/null | grep -q sing-box && ok "TCP ${PROXY_PORT} 监听中（Reality）" || fail "TCP ${PROXY_PORT} 未监听"
  fi
  if on2; then
    ss -Hlnup "sport = :${PROXY_PORT}" 2>/dev/null | grep -q sing-box && ok "UDP ${PROXY_PORT} 监听中（Hysteria2）" || fail "UDP ${PROXY_PORT} 未监听"
  fi
  [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] && ok "BBR 已启用" || warn "BBR 未启用"

  section "时间"
  time_report

  section "线路"
  kv "线路 1" "$(badge 1)  ${D}国内 → DMIT（Reality）${N}"
  kv "线路 2" "$(badge 2)  ${D}国内 → DMIT（Hysteria2）${N}"
  kv "线路 3" "$(badge 3)  ${D}国内 → DMIT → 新泽西${N}"

  section "参数"
  kv "公网 IP " "${PUB_IP:-?}"
  kv "伪装站点" "$SNI"
  if nj_on; then
    local rip; rip=$(getent ahostsv4 "$NJ_HOST" | awk '{print $1; exit}' || true)
    kv "新泽西　" "$NJ_HOST:$NJ_PORT  ${D}(当前解析 ${rip:-失败} · SSH $(ssh_user)@:$(ssh_port))${N}"
    section "线路 3 连通性"
    if tcp_ok "$NJ_HOST" "$NJ_PORT"; then
      ok "DMIT → 新泽西 $NJ_PORT/tcp 可达"
      info "端口可达但线路 3 仍不通时，最常见原因是家里时间偏差 > 30 秒 → ./dmit-setup.sh 13 检查"
    else
      fail "DMIT → 新泽西 $NJ_PORT/tcp 不通 → ./dmit-setup.sh 12 部署，或检查路由器转发、DDNS"
    fi
  fi

  section "流量 ${D}（本次开机以来；DMIT 按进+出双向计费）${N}"
  local ifc rx tx
  ifc=$(ip -4 route show default | awk '{print $5; exit}')
  rx=$(<"/sys/class/net/$ifc/statistics/rx_bytes"); tx=$(<"/sys/class/net/$ifc/statistics/tx_bytes")
  kv "入站" "$(numfmt --to=iec --suffix=B "$rx")"
  kv "出站" "$(numfmt --to=iec --suffix=B "$tx")"
  kv "合计" "${B}$(numfmt --to=iec --suffix=B $((rx + tx)))${N}  ${D}月额度 1000GB · 准确用量以 DMIT 面板为准${N}"
}

cmd_time() {
  need_root
  section "时间同步 ${D}（SS2022 要求两端误差 < 30 秒）${N}"
  base_deps
  fix_time
}

cmd_log() { need_installed; section "最近 50 行日志"; journalctl -u sing-box -n 50 --no-pager; }

cmd_toggle() {
  need_root; need_installed; load
  local n=$1 want=${2:-} key cur new
  [[ $n == 3 ]] && ! nj_on && { warn "线路 3 还没配置，先运行 ./dmit-setup.sh 9"; return 0; }
  key=LINE${n}_ON; cur=${!key:-1}
  case $want in
    on) new=1 ;; off) new=0 ;; "") new=$((1 - cur)) ;;
    *) die "只能是 on 或 off" ;;
  esac
  save "$key" "$new"
  section "线路 $n：$( ((new)) && echo 开启 || echo 关闭 )"
  apply
  ((new)) && ok "线路 $n 已开启" || ok "线路 $n 已关闭 ${D}（密钥保留，重新开启后链接不变）${N}"
  kv "线路" "① $(badge 1)   ② $(badge 2)   ③ $(badge 3)"
}

cmd_sni() {
  need_root; need_installed; load
  local new=${1:-}
  [[ -n $new ]] || ask new "新的伪装站点" "$SNI"
  check_sni "$new"
  save SNI "$new"
  apply
  ok "伪装站点已改为 $new ${D}（线路 1 和 3 需要重新导入）${N}"
  show_links
}

cmd_nj() {
  need_root; need_installed
  section "配置 / 修改线路 3"
  local old_port; load; old_port=${NJ_PORT:-}
  nj_prompt force; apply; write_nj_script
  load
  if [[ -n $old_port && $old_port != "$NJ_PORT" ]]; then
    warn "端口变了，家里中转端需要重新部署 → ./dmit-setup.sh 12"
  fi
  show_links
}

cmd_ddns() {
  need_root; need_installed; load
  nj_on || { warn "线路 3 还没配置，先运行 ./dmit-setup.sh 9"; return 0; }
  local new=${1:-} rip
  section "更换家中 DDNS 域名"
  kv "当前" "$NJ_HOST"
  [[ -n $new ]] || ask new "新的 DDNS 域名" "$NJ_HOST"
  [[ $new == "$NJ_HOST" ]] && { info "没有变化"; return 0; }
  rip=$(getent ahostsv4 "$new" | awk '{print $1; exit}' || true)
  if [[ -n $rip ]]; then ok "$new 当前解析为 $rip"
  else warn "$new 暂时解析不到（DDNS 还没生效？），先照样保存"; fi
  save NJ_HOST "$new"
  apply; write_nj_script >/dev/null
  ok "家中 DDNS 域名已改为 $new ${D}（客户端链接不变，家里中转端不用重装）${N}"
  if tcp_ok "$new" "$NJ_PORT"; then ok "DMIT → $new:$NJ_PORT 可达"
  else warn "DMIT → $new:$NJ_PORT 暂时不通，DDNS 生效后用 ./dmit-setup.sh 3 再测"; fi
}

cmd_nj_push() {
  need_root; need_installed; load
  nj_on || { warn "线路 3 还没配置，先运行 ./dmit-setup.sh 9"; return 0; }
  local t; t="$(ssh_user)@${NJ_HOST}"
  section "一键部署家里中转端"
  kv "目标" "$t  ${D}SSH 端口 $(ssh_port)${N}"
  write_nj_script >/dev/null
  info "接下来需要输入家里机器的 SSH 密码（拷贝一次、安装一次）"
  scp -q -P "$(ssh_port)" -o ConnectTimeout=10 "$NJ_SCRIPT" "${t}:~/nj-setup.sh" \
    || die "拷贝失败：检查家里 SSH 用户名 / 端口（./dmit-setup.sh 9 可修改）"
  ok "脚本已拷到家里"
  ssh -t -p "$(ssh_port)" -o ConnectTimeout=10 "$t" "$(remote_run) install" \
    || die "家里执行失败，看上面的输出"
  section "回到 DMIT 验证"
  if tcp_ok "$NJ_HOST" "$NJ_PORT"; then ok "DMIT → 新泽西 $NJ_PORT/tcp 可达，线路 3 可以用了"
  else fail "DMIT 仍连不上 $NJ_HOST:$NJ_PORT → 检查路由器是否把 $NJ_PORT 的 TCP+UDP 转发到这台机器"; fi
}

cmd_nj_status() {
  need_root; need_installed; load
  nj_on || { warn "线路 3 还没配置，先运行 ./dmit-setup.sh 9"; return 0; }
  ssh -t -p "$(ssh_port)" -o ConnectTimeout=10 "$(ssh_user)@${NJ_HOST}" "$(remote_run) status" \
    || warn "获取失败：家里还没部署新版中转端的话，先 ./dmit-setup.sh 12"
}

cmd_nj_delete() {
  need_root; need_installed; load
  nj_on || { warn "线路 3 本来就没配置"; return 0; }
  warn "将删除线路 3 的全部配置和密钥（只想暂停请用 ./dmit-setup.sh 7）"
  confirm "确定删除吗" || return 0
  for k in NJ_HOST NJ_PORT NJ_SS_KEY UUID_NJ LINE3_ON NJ_SSH_USER NJ_SSH_PORT; do unsave "$k"; done
  unset NJ_HOST NJ_PORT NJ_SS_KEY UUID_NJ LINE3_ON NJ_SSH_USER NJ_SSH_PORT
  apply; rm -f "$NJ_SCRIPT"
  ok "线路 3 配置已删除 ${D}（家里的中转端：bash nj-setup.sh uninstall）${N}"
}

cmd_update() {
  need_root; need_installed
  section "更新 sing-box"
  install_singbox
  "$SB_BIN" check -c "$SB_DIR/config.json" || die "新版本不兼容当前配置"
  apply
  load; if nj_on; then write_nj_script >/dev/null; info "家里中转端要同步升级的话：./dmit-setup.sh 12"; fi
}

cmd_reset() {
  need_root; need_installed
  warn "将重新生成全部密钥，所有旧链接失效，家里的中转端也要重装（./dmit-setup.sh 12）"
  confirm "确定吗" || return 0
  local h p u sp; load; h=${NJ_HOST:-}; p=${NJ_PORT:-}; u=${NJ_SSH_USER:-}; sp=${NJ_SSH_PORT:-}
  rm -f "$SECRETS" "$SB_DIR/hy2.crt" "$SB_DIR/hy2.key"
  unset SNI UUID REALITY_PRIV REALITY_PUB SHORT_ID HY2_PASS HY2_OBFS NJ_HOST NJ_PORT NJ_SS_KEY UUID_NJ \
        LINE1_ON LINE2_ON LINE3_ON PUB_IP NJ_SSH_USER NJ_SSH_PORT
  install -m 600 /dev/null "$SECRETS"
  if [[ -n $h ]]; then
    save NJ_HOST "$h"; save NJ_PORT "$p"
    [[ -n $u ]] && save NJ_SSH_USER "$u"; [[ -n $sp ]] && save NJ_SSH_PORT "$sp"
  fi
  cmd_install
}

cmd_uninstall() {
  need_root
  warn "将删除 sing-box、全部配置、密钥和 dmit 命令"
  confirm "确定卸载吗" || return 0
  systemctl disable --now sing-box dmit-timesync.timer 2>/dev/null || true
  rm -rf "$SB_DIR" "$STATE_DIR" /etc/systemd/system/sing-box.service /etc/sysctl.d/99-dmit-relay.conf \
         /usr/local/lib/dmit-relay /etc/systemd/system/dmit-timesync.service /etc/systemd/system/dmit-timesync.timer \
         "$SB_BIN" "$LINKS" "$NJ_SCRIPT" "$SELF"
  systemctl daemon-reload
  ok "已卸载 ${D}（NTP 对时保留；家里的中转端：bash nj-setup.sh uninstall）${N}"
  ((MENU_MODE)) && exit 0
  return 0
}

cmd_files() {
  section "文件位置"
  kv "管理命令" "$SELF"
  kv "密钥参数" "$SECRETS"
  kv "服务配置" "$SB_DIR/config.json"
  kv "客户端链" "$LINKS"
  kv "家里脚本" "$NJ_SCRIPT"
  kv "服务名称" "sing-box.service（家里是 dmit-relay.service）"
}

cmd_help() {
  banner
  cat <<EOF
  ${B}用法${N}  ./dmit-setup.sh ${C}<编号或命令>${N}      不带参数打开菜单
        ${D}安装后 dmit 等同于 ./dmit-setup.sh，比如 dmit 3${N}

  ${B}查看${N}
    ${C} 1${N} links         客户端链接
    ${C} 2${N} qr            二维码（手机扫码）
    ${C} 3${N} status        运行状态、线路开关、连通性、时间、流量
    ${C} 4${N} log           最近日志

  ${B}线路开关${N}    ${D}可加 on / off 指定，不加则切换，如 ./dmit-setup.sh 5 off${N}
    ${C} 5${N} line1         开 / 关 线路 1（Reality → DMIT）
    ${C} 6${N} line2         开 / 关 线路 2（Hy2 → DMIT）
    ${C} 7${N} line3         开 / 关 线路 3（→ 新泽西）

  ${B}参数${N}
    ${C} 8${N} sni [域名]    更换 Reality 伪装站点
    ${C} 9${N} nj            配置 / 修改线路 3（域名、端口、家里 SSH）
    ${C}10${N} ddns [域名]   更换家中 DDNS 域名

  ${B}家里中转端${N}
    ${C}11${N} nj-hint       手动安装步骤
    ${C}12${N} nj-push       一键部署（SSH 推送并安装，含自动对时）
    ${C}13${N} nj-status     查看家里状态（服务、时间偏差、DDNS）
    ${C}14${N} nj-delete     删除线路 3 配置

  ${B}维护${N}
    ${C}15${N} install       安装 / 重新部署（沿用密钥）
    ${C}16${N} update        更新 sing-box
    ${C}17${N} reset         重新生成全部密钥（泄露时用）
    ${C}18${N} uninstall     卸载
    ${C}19${N} files         文件位置
    ${C}20${N} help          本帮助
    ${C}21${N} time          立即对时（NTP + HTTPS 兜底，家里是 nj-setup.sh time）
EOF
}

run() {
  local c=${1:-} a=${2:-}
  case $c in
    1|links)        need_installed; show_links ;;
    2|qr)           need_installed; show_qr ;;
    3|status)       cmd_status ;;
    4|log)          cmd_log ;;
    5|line1)        cmd_toggle 1 "$a" ;;
    6|line2)        cmd_toggle 2 "$a" ;;
    7|line3)        cmd_toggle 3 "$a" ;;
    8|sni)          cmd_sni "$a" ;;
    9|nj)           cmd_nj ;;
    10|ddns)        cmd_ddns "$a" ;;
    11|nj-hint)     need_installed; nj_hint ;;
    12|nj-push)     cmd_nj_push ;;
    13|nj-status)   cmd_nj_status ;;
    14|nj-delete)   cmd_nj_delete ;;
    15|install)     cmd_install ;;
    16|update)      cmd_update ;;
    17|reset)       cmd_reset ;;
    18|uninstall)   cmd_uninstall ;;
    19|files)       cmd_files ;;
    20|help|-h|--help) cmd_help ;;
    21|time)        cmd_time ;;
    *)              cmd_help; return 1 ;;
  esac
}

# ============================================================================ 菜单
menu_header() {
  load
  [[ -n ${PUB_IP:-} ]] || detect_ip >/dev/null
  clear 2>/dev/null || true
  banner
  kv "服务" "$(systemctl is-active --quiet sing-box && echo "${G}● 运行中${N}" || echo "${R}● 未运行${N}")  ${D}sing-box v$(sb_ver) · ${PUB_IP}:${PROXY_PORT} · 伪装 ${SNI}${N}"
  kv "线路" "① Reality→DMIT $(badge 1)   ② Hy2→DMIT $(badge 2)   ③ →新泽西 $(badge 3)"
  nj_on && kv "家中" "${D}${NJ_HOST}:${NJ_PORT} · SSH $(ssh_user)@:$(ssh_port)${N}"
  hr
}

menu_body() {
  cat <<EOF
  ${B}查看${N}
    ${C} 1${N}  客户端链接                ${C} 2${N}  二维码（手机扫码）
    ${C} 3${N}  运行状态与流量            ${C} 4${N}  最近日志

  ${B}线路开关${N}
    ${C} 5${N}  开 / 关 线路 1            ${C} 6${N}  开 / 关 线路 2
    ${C} 7${N}  开 / 关 线路 3

  ${B}参数${N}
    ${C} 8${N}  更换 Reality 伪装站点     ${C} 9${N}  配置 / 修改线路 3
    ${C}10${N}  更换家中 DDNS 域名

  ${B}家里中转端${N}
    ${C}11${N}  手动安装步骤              ${C}12${N}  一键部署（SSH）
    ${C}13${N}  查看家里状态              ${C}14${N}  删除线路 3 配置

  ${B}维护${N}
    ${C}15${N}  重新部署（沿用密钥）      ${C}16${N}  更新 sing-box
    ${C}17${N}  重新生成全部密钥          ${C}18${N}  卸载

    ${C}19${N}  文件位置                  ${C}20${N}  命令行用法
    ${C}21${N}  立即对时
    ${C} 0${N}  退出
EOF
  hr
}

cmd_menu() {
  need_root
  [[ -f $SB_DIR/config.json && -f $SECRETS ]] || { cmd_install; return; }
  install_self
  MENU_MODE=1
  local c
  while true; do
    menu_header; menu_body
    read -rp "  ${M}?${N} 选择 [0-21]: " c
    case $c in
      0|q|"") echo; exit 0 ;;
      *) run "$c" || true ;;
    esac
    echo; read -rp "  ${D}回车返回菜单…${N}" _
  done
}

# ============================================================================ 入口
if [[ $# -eq 0 ]]; then cmd_menu; else run "$@"; fi
