#!/usr/bin/env bash
# 从上游源码构建 sing-box 和 hysteria（linux amd64 / arm64），产物放进 bin/
#
#   scripts/build-bins.sh                    构建 bin/versions.env 里记录的版本
#   scripts/build-bins.sh latest             构建上游最新正式版
#   scripts/build-bins.sh 1.14.2 2.12.3      构建指定版本（sing-box hysteria）
#
# 产物：bin/<程序>-linux-<架构>.gz、bin/SHA256SUMS、bin/versions.env
# 需要：git、go、gzip、sha256sum。Go 工具链固定用上游 go.mod 声明的版本（自动下载），
# 所以同一版本在哪里构建产物都逐字节相同，CI 会重新构建并比对。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/bin
ARCHES=(amd64 arm64)
SB_REPO=https://github.com/SagerNet/sing-box
HY_REPO=https://github.com/apernet/hysteria

latest_tag() {  # latest_tag 仓库 前缀：列出正式版 tag 里最新的一个（去掉前缀）
  git ls-remote --tags --refs "$1" | awk '{print $2}' | sed -n "s#^refs/tags/$2##p" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}

case ${1:-} in
  latest) SB_VER=$(latest_tag "$SB_REPO" v); HY_VER=$(latest_tag "$HY_REPO" app/v) ;;
  "")     source "$BIN/versions.env"; SB_VER=$SING_BOX_VERSION; HY_VER=$HYSTERIA_VERSION ;;
  *)      SB_VER=$1; HY_VER=${2:?用法：build-bins.sh <sing-box 版本> <hysteria 版本>} ;;
esac
[[ -n $SB_VER && -n $HY_VER ]] || { echo "取不到版本号" >&2; exit 1; }
echo "sing-box $SB_VER · hysteria $HY_VER"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export CGO_ENABLED=0 GOFLAGS=-buildvcs=false TZ=UTC
pin_go() { GOTOOLCHAIN=go$(awk '$1 == "go" {print $2; exit}' "$1"); export GOTOOLCHAIN; }

# ---- sing-box：参数与上游 Makefile 的 build 目标一致
git clone -q --depth 1 -b "v$SB_VER" "$SB_REPO" "$WORK/sing-box"
(
  cd "$WORK/sing-box"
  pin_go go.mod
  tags=$(cat release/DEFAULT_BUILD_TAGS_OTHERS)
  ldflags="-X 'github.com/sagernet/sing-box/constant.Version=$SB_VER' $(cat release/LDFLAGS) -s -w -buildid="
  for a in "${ARCHES[@]}"; do
    echo "构建 sing-box linux/$a"
    GOOS=linux GOARCH=$a go build -trimpath -tags "$tags" -ldflags "$ldflags" -o "$WORK/out/sing-box-linux-$a" ./cmd/sing-box
  done
)

# ---- hysteria：参数与上游 hyperbole.py 的 release 构建（build -r）一致，
#      只有 appDate 用 tag 的提交时间而不是当前时间，这样结果才能复现
git clone -q --depth 1 -b "app/v$HY_VER" "$HY_REPO" "$WORK/hysteria"
(
  cd "$WORK/hysteria"
  pin_go app/go.mod
  pkg=github.com/apernet/hysteria/app/v2/cmd
  commit=$(git rev-parse HEAD)
  date=$(git log -1 --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ')
  lib=$(awk '$1 == "github.com/apernet/quic-go" {print $2; exit}' core/go.mod)
  toolchain=$(cd app && go version | sed 's/^go version //')
  for a in "${ARCHES[@]}"; do
    echo "构建 hysteria linux/$a"
    ldflags="-X $pkg.appVersion=v$HY_VER -X $pkg.appDate=$date -X $pkg.appType=release"
    ldflags+=" -X '$pkg.appToolchain=$toolchain' -X $pkg.appCommit=$commit -X $pkg.libVersion=$lib"
    ldflags+=" -X $pkg.appPlatform=linux -X $pkg.appArch=$a -s -w -buildid="
    GOOS=linux GOARCH=$a go build -C app -trimpath -ldflags "$ldflags" -o "$WORK/out/hysteria-linux-$a" .
  done
)

# ---- 压缩、校验和、版本号
mkdir -p "$BIN"
rm -f "$BIN"/*.gz
for f in "$WORK"/out/*; do gzip -n -9 -c "$f" >"$BIN/$(basename "$f").gz"; done
(cd "$BIN" && sha256sum ./*.gz | sed 's# \./# #' >SHA256SUMS)
printf 'SING_BOX_VERSION=%s\nHYSTERIA_VERSION=%s\n' "$SB_VER" "$HY_VER" >"$BIN/versions.env"
ls -l "$BIN"
