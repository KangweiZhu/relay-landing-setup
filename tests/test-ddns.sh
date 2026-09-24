#!/usr/bin/env bash
# ddns/cf-ddns.sh 的离线测试：起一个假 Cloudflare，逐个场景检查行为
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); PORT=${PORT:-18765}
: >"$T/puts.log"
python3 "$ROOT/tests/cf-mock.py" "$PORT" "$T" & MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$T"' EXIT
export NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
export CF_API=http://127.0.0.1:$PORT CF_DDNS_CACHE=$T/cache
export CF_DDNS_IP_URL1=http://127.0.0.1:$PORT/ip1 CF_DDNS_IP_URL2=http://127.0.0.1:$PORT/ip2
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done

pass=0 fail=0
check() {  # check 名称 期望退出码 期望 PUT 次数 期望输出片段 -- 参数...
  local name=$1 want_rc=$2 want_puts=$3 want_out=$4; shift 5
  local before rc=0 out puts
  before=$(wc -l <"$T/puts.log" 2>/dev/null || echo 0)
  out=$("$ROOT/ddns/cf-ddns.sh" "$@" 2>&1) || rc=$?
  puts=$(( $(wc -l <"$T/puts.log" 2>/dev/null || echo 0) - before ))
  if [[ $rc == "$want_rc" && $puts == "$want_puts" && $out == *"$want_out"* ]]; then
    pass=$((pass + 1)); echo "  ✔ $name"
  else
    fail=$((fail + 1)); echo "  ✘ $name：退出码 $rc（应为 $want_rc），PUT $puts 次（应为 $want_puts），输出：$out"
  fi
}
OK=(-k testkey -u me@example.com -h ddns -z kz7.site)

echo 1.2.3.4 >"$T/ip1"; echo 1.2.3.4 >"$T/ip2"
check "首次运行会更新"             0 1 "ddns.kz7.site → 1.2.3.4 已更新" -- "${OK[@]}"
grep -q '"content":"1.2.3.4"' "$T/puts.log" && grep -q '"name":"ddns.kz7.site"' "$T/puts.log" \
  && { pass=$((pass + 1)); echo "  ✔ 请求体里是完整主机名和新 IP"; } || { fail=$((fail + 1)); echo "  ✘ 请求体不对：$(cat "$T/puts.log")"; }
check "IP 没变不调接口"            0 0 ""                                -- "${OK[@]}"
check "-f true 强制更新"           0 1 "已更新"                          -- "${OK[@]}" -f true
echo 5.6.7.8 >"$T/ip1"; echo 5.6.7.8 >"$T/ip2"
check "IP 变了会更新"              0 1 "→ 5.6.7.8 已更新"                -- "${OK[@]}"
echo 9.9.9.9 >"$T/ip2"
check "两个来源不一致不更新"       1 0 "不一致"                          -- "${OK[@]}"
echo 'not-an-ip' >"$T/ip1"
check "IP 格式不对不更新"          1 0 "查不到公网 IP"                   -- "${OK[@]}"
echo 1.1.1.1 >"$T/ip1"; echo 1.1.1.1 >"$T/ip2"; rm -rf "$T/cache"
check "Key 错误报错"               1 0 "找不到域名"                      -- -k wrong -u me@example.com -h ddns -z kz7.site
check "记录不存在报错"             1 0 "找不到 A 记录 nope.kz7.site"     -- -k testkey -u me@example.com -h nope -z kz7.site
check "-t 只接受 A / AAAA"         1 0 "-t 只能是 A 或 AAAA"             -- "${OK[@]}" -t MX
check "缺参数报错"                 1 0 "缺少 -k"                         -- -u me@example.com -h ddns -z kz7.site
check "改完恢复正常"               0 1 "→ 1.1.1.1 已更新"                -- "${OK[@]}"

echo; echo "通过 $pass，失败 $fail"
((fail == 0))
