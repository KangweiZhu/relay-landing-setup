# relay-landing-setup

DMIT 落地 + 新泽西家宽中转，一键部署脚本、自建的 sing-box / hysteria 程序和 Cloudflare DDNS。

| 线路 | 路径 | 出口 |
|---|---|---|
| 1 | 国内 ─Reality─> DMIT | DMIT |
| 2 | 国内 ─Hy2─> DMIT | DMIT |
| 3 | 国内 ─Reality─> DMIT ─SS2022─> 新泽西 | 家宽 |
| 4 | 国内 ─Hy2─> 新泽西 | 家宽（家里现有的，脚本不碰） |

## 用法

在 DMIT 上（Debian / Ubuntu，root）：

```bash
curl -fsSLO https://raw.githubusercontent.com/KangweiZhu/relay-landing-setup/main/dmit-setup.sh
bash dmit-setup.sh          # 未安装时自动安装，之后打开菜单；装好后可以直接用 dmit
```

家里的中转端不用单独下载：在 DMIT 上运行 `dmit 12`，脚本会生成 `nj-setup.sh`，拷到家里并安装。

## 目录

| 路径 | 内容 |
|---|---|
| `dmit-setup.sh` | DMIT 端安装与管理；家里的 `nj-setup.sh` 也由它生成 |
| `bin/` | 从上游源码构建的 sing-box、hysteria（linux amd64 / arm64，gzip），`SHA256SUMS`，`versions.env` |
| `ddns/cf-ddns.sh` | Cloudflare DDNS（Global API Key），参数和 cf-v4-ddns.sh 相同 |
| `scripts/build-bins.sh` | 构建 `bin/` 的脚本，本地和 CI 共用 |
| `tests/` | 离线测试：配置校验、nj-setup.sh 生成、假 Cloudflare 下的 DDNS |

## 程序从哪来

两端安装的 sing-box 都从本仓库的 `bin/` 下载，并且 sha256 对上才会安装。家里用的校验表是 DMIT 生成 `nj-setup.sh` 时一起带过去的，所以两端装的一定是同一份程序。

`bin/` 里的程序由 `scripts/build-bins.sh` 从上游源码构建：

- sing-box：[SagerNet/sing-box](https://github.com/SagerNet/sing-box)，构建参数和上游 `make build` 一致
- hysteria：[apernet/hysteria](https://github.com/apernet/hysteria)，构建参数和上游 `hyperbole.py build -r` 一致，只是构建日期用 tag 的提交时间（否则每次构建结果都不同）

Go 版本固定为上游 `go.mod` 里声明的版本，所以构建结果可以复现。

## CI

| Workflow | 触发 | 做什么 |
|---|---|---|
| CI | 每次 push / PR | shellcheck、actionlint；在 x86 和 ARM 上跑测试；在 Debian 12/13、Ubuntu 22.04/24.04 空白容器里补依赖 |
| 复现构建 | `bin/` 或构建脚本变化时 | 从源码重新构建，和仓库里的程序逐字节比对 |
| 更新构建产物 | 每周一或手动（可指定版本） | 构建上游最新正式版，测试通过后提交到 `bin/` |

## DDNS

```bash
cf-ddns.sh -k <Global API Key> -u <CF 邮箱> -h ddns.kz7.site -z kz7.site
```

也可以把参数写进 `/etc/cf-ddns.env`，然后运行 `cf-ddns.sh install`，装一个每分钟更新一次的 systemd timer。详细说明见脚本开头的注释。
