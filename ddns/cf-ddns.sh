#!/usr/bin/env bash
# ============================================================================
#  Cloudflare DDNS（API v4，Global API Key）
#
#  参数和 yulewang/cloudflare-api-v4-ddns 的 cf-v4-ddns.sh 一样，可以直接替换：
#    cf-ddns.sh -k <Global API Key> -u <CF 账号邮箱> -h <主机名> -z <根域名> [-t A|AAAA] [-f true]
#    例：cf-ddns.sh -k xxxx -u me@example.com -h ddns.kz7.site -z kz7.site
#
#  参数也可以写进 /etc/cf-ddns.env，命令行参数优先：
#    CFKEY=...  CFUSER=...  CFZONE_NAME=kz7.site  CFRECORD_NAME=ddns.kz7.site  CFRECORD_TYPE=A
#
#  定时运行（二选一）：
#    crontab：*/1 * * * * /usr/local/bin/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1
#    systemd：cf-ddns.sh install 会装好每分钟一次的 timer（参数须已写进 /etc/cf-ddns.env）
#
#  和原脚本的区别：
#    - 用 https 查公网 IP，并且两个来源结果一致才更新（原脚本用明文 http，可被篡改）
#    - -t AAAA 真正生效（原脚本在读参数之前就定死了查 IPv4）
#    - 记录不存在时直接报错，不会带着空 ID 去调接口
#    - 缓存放在 /var/cache/cf-ddns，日志带时间
# ============================================================================
set -euo pipefail

CONF=/etc/cf-ddns.env
CACHE_DIR=${CF_DDNS_CACHE:-/var/cache/cf-ddns}
API=${CF_API:-https://api.cloudflare.com/client/v4}
IP_URL1=${CF_DDNS_IP_URL1:-https://api.ipify.org}   # 两个环境变量仅供测试时替换
IP_URL2=${CF_DDNS_IP_URL2:-https://icanhazip.com}

CFKEY='' CFUSER='' CFZONE_NAME='' CFRECORD_NAME='' CFRECORD_TYPE=A CFTTL=120 FORCE=false
[[ -r $CONF ]] && source "$CONF"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die() { log "错误：$*" >&2; exit 1; }

install_timer() {
  [[ $EUID -eq 0 ]] || die "请用 root 运行"
  [[ -r $CONF ]] || die "先把参数写进 $CONF（CFKEY CFUSER CFZONE_NAME CFRECORD_NAME）"
  chmod 600 "$CONF"
  install -m 755 "$(realpath "$0")" /usr/local/bin/cf-ddns.sh
  cat >/etc/systemd/system/cf-ddns.service <<'EOF'
[Unit]
Description=Cloudflare DDNS update
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/cf-ddns.sh
EOF
  cat >/etc/systemd/system/cf-ddns.timer <<'EOF'
[Unit]
Description=Run Cloudflare DDNS update every minute
[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now cf-ddns.timer
  log "已安装：每分钟更新一次，日志用 journalctl -u cf-ddns 查看"
}

if [[ ${1:-} == install ]]; then install_timer; exit 0; fi

while getopts k:u:h:z:t:f: o; do
  case $o in
    k) CFKEY=$OPTARG ;; u) CFUSER=$OPTARG ;; h) CFRECORD_NAME=$OPTARG ;;
    z) CFZONE_NAME=$OPTARG ;; t) CFRECORD_TYPE=$OPTARG ;; f) FORCE=$OPTARG ;;
    *) exit 2 ;;
  esac
done

[[ -n $CFKEY ]]         || die "缺少 -k（Global API Key，在 Cloudflare 个人资料 → API 令牌 页面查看）"
[[ -n $CFUSER ]]        || die "缺少 -u（Cloudflare 账号邮箱）"
[[ -n $CFZONE_NAME ]]   || die "缺少 -z（根域名，例如 kz7.site）"
[[ -n $CFRECORD_NAME ]] || die "缺少 -h（要更新的主机名，例如 ddns.kz7.site）"
# 主机名不带根域名时自动补上，和原脚本一致
if [[ $CFRECORD_NAME != "$CFZONE_NAME" && $CFRECORD_NAME != *".$CFZONE_NAME" ]]; then
  CFRECORD_NAME=$CFRECORD_NAME.$CFZONE_NAME
fi

case $CFRECORD_TYPE in
  A)    ipflag=-4 ipre='^([0-9]{1,3}\.){3}[0-9]{1,3}$' ;;
  AAAA) ipflag=-6 ipre='^[0-9a-fA-F:]+$' ;;
  *)    die "-t 只能是 A 或 AAAA" ;;
esac

# ---- 公网 IP：两个 https 来源一致才采信
get_ip() { curl "$ipflag" -fsS --max-time 8 "$1" 2>/dev/null | tr -d '[:space:]'; }
ip1=$(get_ip "$IP_URL1" || true)
ip2=$(get_ip "$IP_URL2" || true)
[[ $ip1 =~ $ipre ]] || die "查不到公网 IP（$IP_URL1 返回：${ip1:-空}）"
[[ $ip1 == "$ip2" ]] || die "两个来源的公网 IP 不一致（$ip1 / ${ip2:-空}），这次不更新"
WAN_IP=$ip1

mkdir -p "$CACHE_DIR"; chmod 700 "$CACHE_DIR"
IP_FILE=$CACHE_DIR/$CFRECORD_NAME.$CFRECORD_TYPE.ip
ID_FILE=$CACHE_DIR/$CFRECORD_NAME.$CFRECORD_TYPE.id

if [[ $FORCE != true && -f $IP_FILE && $(<"$IP_FILE") == "$WAN_IP" ]]; then
  exit 0   # IP 没变，安静退出（cron 每分钟跑，不刷日志）
fi

cf() {  # cf 方法 路径 [数据]
  curl -sS --max-time 15 -X "$1" "$API$2" \
    -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" \
    ${3:+--data "$3"}
}
first_id() { grep -o '"id": *"[0-9a-f]\{32\}"' | head -1 | sed 's/.*"\([0-9a-f]*\)"/\1/'; }

# ---- zone / record ID：有缓存且对得上就用缓存
if [[ -f $ID_FILE ]] && mapfile -t ids <"$ID_FILE" && ((${#ids[@]} == 3)) && [[ ${ids[2]} == "$CFZONE_NAME" ]]; then
  ZONE_ID=${ids[0]} RECORD_ID=${ids[1]}
else
  ZONE_ID=$(cf GET "/zones?name=$CFZONE_NAME" | first_id) || true
  [[ -n $ZONE_ID ]] || die "找不到域名 $CFZONE_NAME（检查 -z、邮箱和 API Key）"
  RECORD_ID=$(cf GET "/zones/$ZONE_ID/dns_records?type=$CFRECORD_TYPE&name=$CFRECORD_NAME" | first_id) || true
  [[ -n $RECORD_ID ]] || die "找不到 $CFRECORD_TYPE 记录 $CFRECORD_NAME，请先在 Cloudflare 面板里建一条"
  printf '%s\n' "$ZONE_ID" "$RECORD_ID" "$CFZONE_NAME" >"$ID_FILE"
fi

body=$(printf '{"type":"%s","name":"%s","content":"%s","ttl":%s}' "$CFRECORD_TYPE" "$CFRECORD_NAME" "$WAN_IP" "$CFTTL")
if resp=$(cf PUT "/zones/$ZONE_ID/dns_records/$RECORD_ID" "$body") && grep -q '"success": *true' <<<"$resp"; then
  echo "$WAN_IP" >"$IP_FILE"
  log "$CFRECORD_NAME → $WAN_IP 已更新"
else
  rm -f "$ID_FILE"   # ID 可能过期了，下次重新查
  die "更新失败：${resp:-无响应}"
fi
