#!/usr/bin/env bash
# dmit-setup.sh 的离线测试：用 bin/ 里的 sing-box 校验所有线路组合的配置，
# 生成家里的 nj-setup.sh 并校验它的语法和配置
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok_()  { pass=$((pass + 1)); echo "  ✔ $*"; }
bad_() { fail=$((fail + 1)); echo "  ✘ $*"; }

case "$(uname -m)" in x86_64) A=amd64 ;; aarch64) A=arm64 ;; esac
(cd "$ROOT/bin" && sha256sum -c --quiet SHA256SUMS) && ok_ "bin/ 里的产物和 SHA256SUMS 一致" || bad_ "bin/ 校验失败"
gunzip -c "$ROOT/bin/sing-box-linux-$A.gz" >"$T/sing-box"; chmod 755 "$T/sing-box"
source "$ROOT/bin/versions.env"
[[ $("$T/sing-box" version | awk 'NR==1{print $3}') == "$SING_BOX_VERSION" ]] \
  && ok_ "sing-box 版本和 versions.env 一致（$SING_BOX_VERSION）" || bad_ "sing-box 版本和 versions.env 不一致"
gunzip -c "$ROOT/bin/hysteria-linux-$A.gz" >"$T/hysteria"; chmod 755 "$T/hysteria"
"$T/hysteria" version | grep -q "v$HYSTERIA_VERSION" \
  && ok_ "hysteria 版本和 versions.env 一致（$HYSTERIA_VERSION）" || bad_ "hysteria 版本和 versions.env 不一致"

# 载入 dmit-setup.sh 的函数（去掉最后一行入口），路径全部指到临时目录
head -n -1 "$ROOT/dmit-setup.sh" >"$T/lib.sh"
# shellcheck disable=SC2034  # 这些变量给 source 进来的 dmit-setup.sh 函数用
run_dmit() {  # 在子 shell 里执行，die 只会结束子 shell
  ( source "$T/lib.sh"
    SB_BIN=$T/sing-box SB_DIR=$T/sb STATE_DIR=$T/state SECRETS=$T/state/secrets.env
    NJ_SCRIPT=$T/nj-setup.sh LINKS=$T/links.txt SB_SUMS_FILE=$T/state/sing-box.sha256
    mkdir -p "$SB_DIR" "$STATE_DIR"
    eval "$1" )
}

# 用真的 sing-box 生成一套密钥
kp=$("$T/sing-box" generate reality-keypair)
mkdir -p "$T/state"
grep ' sing-box-linux-' "$ROOT/bin/SHA256SUMS" >"$T/state/sing-box.sha256"
{
  printf 'SNI=www.microsoft.com\nUUID=%s\nUUID_NJ=%s\n' "$("$T/sing-box" generate uuid)" "$("$T/sing-box" generate uuid)"
  printf 'REALITY_PRIV=%s\nREALITY_PUB=%s\n' "$(awk '/PrivateKey/{print $2}' <<<"$kp")" "$(awk '/PublicKey/{print $2}' <<<"$kp")"
  printf 'SHORT_ID=%s\nHY2_PASS=%s\nHY2_OBFS=%s\n' "$("$T/sing-box" generate rand 8 --hex)" "$("$T/sing-box" generate rand 16 --hex)" "$("$T/sing-box" generate rand 16 --hex)"
  printf 'NJ_SS_KEY=%s\nNJ_HOST=ddns.example.com\nNJ_PORT=40553\nPUB_IP=203.0.113.7\n' "$("$T/sing-box" generate rand 16 --base64)"
} >"$T/state/secrets.env"

# 所有线路开关组合（全关时 write_config 仍应生成合法配置）
for l1 in 0 1; do for l2 in 0 1; do for l3 in 0 1; do
  name="线路开关 1=$l1 2=$l2 3=$l3"
  if out=$(run_dmit "save LINE1_ON $l1; save LINE2_ON $l2; save LINE3_ON $l3; write_config" 2>&1); then
    ok_ "$name：配置通过 sing-box check"
  else
    bad_ "$name：$out"
  fi
done; done; done

# 线路 3 未配置时（没有 NJ_HOST）
cp "$T/state/secrets.env" "$T/secrets.bak"
if out=$(run_dmit "unsave NJ_HOST; unsave LINE3_ON; write_config" 2>&1); then ok_ "未配置线路 3：配置通过"; else bad_ "未配置线路 3：$out"; fi
cp "$T/secrets.bak" "$T/state/secrets.env"

# 客户端链接
run_dmit "save LINE1_ON 1; save LINE2_ON 1; save LINE3_ON 1; build_links" >/dev/null
[[ $(grep -c '^vless://.*security=reality.*#1-dmit-reality$' "$T/links.txt") == 1 \
&& $(grep -c '^hysteria2://.*obfs=salamander.*#2-dmit-hy2$' "$T/links.txt") == 1 \
&& $(grep -c '^vless://.*#3-dmit-to-nj$' "$T/links.txt") == 1 ]] \
  && ok_ "三条客户端链接格式正确" || bad_ "客户端链接不对：$(cat "$T/links.txt")"

# 家里的 nj-setup.sh
run_dmit "sb_ver() { echo $SING_BOX_VERSION; }; write_nj_script" >/dev/null
bash -n "$T/nj-setup.sh" && ok_ "nj-setup.sh 语法正确" || bad_ "nj-setup.sh 语法错误"
if command -v shellcheck >/dev/null; then
  shellcheck -S warning "$T/nj-setup.sh" && ok_ "nj-setup.sh 通过 shellcheck" || bad_ "nj-setup.sh 没通过 shellcheck"
fi
( source <(sed -n '/^NJ_HOST=/,/^SB_SUMS=/p' "$T/nj-setup.sh")
  [[ $NJ_HOST == ddns.example.com && $NJ_PORT == 40553 && $SB_VER == "$SING_BOX_VERSION" ]] \
  && diff <(printf '%s\n' "$SB_SUMS") "$T/state/sing-box.sha256" >/dev/null ) \
  && ok_ "nj-setup.sh 带上了正确的参数、版本和校验表" || bad_ "nj-setup.sh 里的参数不对"
for f in apt_need base_deps fetch_bin fix_time time_report; do
  grep -q "^$f ()" "$T/nj-setup.sh" || { bad_ "nj-setup.sh 缺少共用函数 $f"; continue 2; }
done
ok_ "nj-setup.sh 嵌入了两端共用的函数"
# 家里的 sing-box 配置：把 nj-setup.sh 里的配置模板展开后校验
( source <(sed -n '/^NJ_HOST=/,/^SB_SUMS=/p' "$T/nj-setup.sh")
  eval "cat <<CONF
$(sed -n '/<<CONF$/,/^CONF$/{//!p}' "$T/nj-setup.sh")
CONF" ) >"$T/nj-config.json"
"$T/sing-box" check -c "$T/nj-config.json" && ok_ "家里中转端配置通过 sing-box check" || bad_ "家里中转端配置校验失败"

echo; echo "通过 $pass，失败 $fail"
((fail == 0))
