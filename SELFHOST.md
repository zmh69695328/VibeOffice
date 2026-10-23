# 自托管发布流水线（本 fork 新增）

这个 fork 在**不改动任何应用代码**的前提下，加了两条 GitHub Actions 流水线和一个打包脚本，把 `public/` 变成可以直接部署的静态站点包，方便内网服务器按版本更新。

- 上游项目：<https://github.com/tcchen2026/VibeOffice>（Apache-2.0）
- 本 fork：<https://github.com/zmh69695328/VibeOffice>

> 站点是纯静态 HTML/JavaScript：没有构建步骤、没有后端、没有数据库；打包只是复制文件、写版本号、压缩和校验。服务器上不需要 Node/Python 运行时。

## 1. 新增的文件

| 文件 | 作用 |
|---|---|
| `tools/build-site-bundle.sh` | 本地/CI 共用的打包脚本：复制 `public/` → 写版本号 → 生成 `dist/` 下的站点、tar.gz、zip、校验和、构建信息 |
| `.github/workflows/build-static.yml` | 推送到 `main`、打 `v*` tag 或手动触发时构建；上传 Actions artifact；在 `selfhost-latest` release 放稳定命名的包；tag 构建会创建版本化 release |
| `.github/workflows/sync-upstream.yml` | 可选：手动（或取消注释 schedule 后每天）把上游 `main` rebase 进本 fork，并触发一次构建 |
| `SELFHOST.md` | 本文件 |

## 2. 第一次使用：启用 Actions

GitHub 默认不在 fork 里运行 workflow。进入 fork 的 **Actions** 标签页，点 “I understand my workflows, go ahead and enable them”（或对单条 workflow 点 Enable）。之后推送 `main` 就会自动构建。

## 3. 本地打包（不上传 GitHub 也能用）

```bash
git clone https://github.com/zmh69695328/VibeOffice.git
cd VibeOffice
tools/build-site-bundle.sh          # 输出到 ./dist
```

产物：

```text
dist/
├── site/                                # 直接 rsync 到 Web 根目录
├── VERSION                              # v<yyyy>.<mm>.<dd>-<6位hash>
├── build-info.json                      # 提交、分支、构建时间
├── SHA256SUMS.site                      # site/ 中每个文件的 SHA-256
├── SHA256SUMS                           # 带版本号的两个包的 SHA-256
├── SHA256SUMS.latest                    # 稳定命名副本的 SHA-256
├── README-DEPLOY.txt                    # 包内安装说明
├── vibeoffice-site-<version>.tar.gz
├── vibeoffice-site-<version>.zip
├── vibeoffice-site.tar.gz               # 稳定命名的副本（更新脚本用）
└── vibeoffice-site.zip
```

版本号来自 git 提交日期 + 提交哈希（仓库自带的 `tools/current-tree-version.sh`），会写进 `common/suite.js` 和 `sw.js`，并生成 `updater/web-<version>.zip`（Service Worker 离线包）。内网域名下 Service Worker 默认不启用（上游代码只允许官方域名和 `127.0.0.1`），这个 zip 可保留，不影响使用。

## 4. CI 产物与下载地址

| 触发方式 | 产物位置 | 说明 |
|---|---|---|
| push `main` / 手动运行 | Actions → Build self-host static bundle → 对应 run 的 Artifacts | 需要登录 GitHub 才能下载，保留 90 天 |
| push `main` | Releases → **`selfhost-latest`** | 稳定下载地址，每次构建覆盖，适合更新脚本 |
| push tag `v*` | Releases → 对应 tag | 固定版本归档，适合留档 |

`selfhost-latest` 的稳定地址（把 `zmh69695328` 换成你的实际 fork 属主即可）：

```text
https://github.com/zmh69695328/VibeOffice/releases/download/selfhost-latest/vibeoffice-site.tar.gz
https://github.com/zmh69695328/VibeOffice/releases/download/selfhost-latest/vibeoffice-site.zip
https://github.com/zmh69695328/VibeOffice/releases/download/selfhost-latest/SHA256SUMS.latest
https://github.com/zmh69695328/VibeOffice/releases/download/selfhost-latest/VERSION
https://github.com/zmh69695328/VibeOffice/releases/download/selfhost-latest/build-info.json
```

> 如果 fork 改成私有仓库，下载 release 资源需要带 token（例如 `curl -H "Authorization: Bearer <token>"`）。

## 5. 服务器更新流程

推荐在服务器上放一个更新脚本，例如 `/usr/local/sbin/vibeoffice-update.sh`：

```bash
#!/bin/sh
set -eu

BASE=https://github.com/zmh69695328/VibeOffice/releases/download/selfhost-latest
WEB=/var/www/vibeoffice/site
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$BASE/vibeoffice-site.tar.gz" -o "$TMP/site.tar.gz"
curl -fsSL "$BASE/SHA256SUMS.latest"     -o "$TMP/SHA256SUMS.latest"
curl -fsSL "$BASE/VERSION"               -o "$TMP/VERSION"

# 校验下载的包
(cd "$TMP" && grep ' vibeoffice-site\.tar\.gz$' SHA256SUMS.latest | sha256sum -c -)

tar -xzf "$TMP/site.tar.gz" -C "$TMP"
# 校验解包后的站点文件（可选，205 个文件）
(cd "$TMP" && sha256sum -c SHA256SUMS.site)

sudo rsync -a --delete "$TMP/site/" "$WEB/"
sudo chown -R root:root "$WEB"
sudo find "$WEB" -type d -exec chmod 755 {} +
sudo find "$WEB" -type f -exec chmod 644 {} +
sudo install -m 644 "$TMP/VERSION" /var/www/vibeoffice/version

sudo nginx -t && sudo systemctl reload nginx        # Caddy：sudo systemctl reload caddy
echo "updated to $(cat /var/www/vibeoffice/version)"
```

第一次部署：

```bash
sudo mkdir -p /var/www/vibeoffice
sudo /usr/local/sbin/vibeoffice-update.sh
```

回滚：`selfhost-latest` 只保留最新版本；需要回滚时，下载之前 tag 发布的 `vibeoffice-site-<旧版本>.tar.gz`，解包后同样 rsync 即可。因此建议对重要版本打 tag：

```bash
V=$(tools/current-tree-version.sh)   # 例如 v2026.10.18-32ff53
git tag "$V" && git push origin "$V"
```

## 6. 内网自签 IP 证书的实际情况

### 6.1 能接受的部分

- 页面、三个应用、打开/保存普通 `.docx/.xlsx/.pptx`、导出 PDF：**都能用**。
- 浏览器会提示证书不受信任（自签），点“继续访问”即可；页面本身不会因此报错。
- **Service Worker / 离线缓存 / PWA 安装不可用**——即使证书受信任，上游也只允许 `https://vibeoffice.work` 和 `127.0.0.1` 注册 Service Worker。这一点与你的判断一致，可以接受。
- **密码保护的 Office 文件打不开**：这类文件依赖 WebCrypto，而浏览器只在“安全上下文”里提供。未信任的自签证书不算安全上下文（点“继续访问”也不会变成安全上下文）。

### 6.2 如果希望密码保护文件可用：把自签 CA 装进客户端信任库

生成带 IP SAN 的证书（nginx 示例）：

```bash
sudo mkdir -p /etc/ssl/vibeoffice
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/ssl/vibeoffice/vibeoffice.key \
  -out    /etc/ssl/vibeoffice/vibeoffice.crt \
  -subj   "/CN=VibeOffice Intranet" \
  -addext "subjectAltName=IP:192.168.1.10"
```

nginx 配置里把证书路径改成：

```nginx
ssl_certificate     /etc/ssl/vibeoffice/vibeoffice.crt;
ssl_certificate_key /etc/ssl/vibeoffice/vibeoffice.key;
```

Caddy 可以直接用内部 CA：

```caddyfile
https://192.168.1.10 {
	tls internal
	# root * /var/www/vibeoffice/site ...
}
```

Caddy 的根证书通常在 `/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt`（路径以 `caddy environment` 输出为准）。

然后把 `vibeoffice.crt`（或 Caddy 的 `root.crt`）作为**受信任的根证书**导入每台客户端：

- Windows：`certmgr.msc` → 受信任的根证书颁发机构 → 导入；
- macOS：钥匙串访问 → 系统 → 导入并设为“始终信任”；
- Linux：复制到 `/usr/local/share/ca-certificates/` 后 `update-ca-certificates`；
- Firefox 使用自己的证书库，需要单独导入（设置 → 隐私与安全 → 证书 → 查看证书 → 导入）。

导入后重新打开页面：

| 功能 | 未信任自签证书 | 已信任自签证书 |
|---|---|---|
| 打开/保存普通 Office 文件 | ✅ | ✅ |
| 密码保护的 Office 文件 | ❌ | ✅ |
| 离线缓存 / PWA 安装 | ❌ | ❌（上游域名白名单，内网域名/IP 不启用） |
| 页面显示、字体、打印/PDF | ✅ | ✅ |

> 以后如果确实想要离线：把 `public/sw.js` 和 `public/common/suite.js` 里的 origin 白名单补上内网主机名（部署指南第 9 节的 `build-selfhost-pwa.sh` 就是做这件事），并且证书必须受信任。但这不是本流水线的默认行为。

### 6.3 另一种临时办法：SSH 隧道到 127.0.0.1

在服务器上以 HTTP 监听 `127.0.0.1:8080`，本地执行：

```bash
ssh -N -L 8080:127.0.0.1:8080 user@server
```

浏览器打开 `http://127.0.0.1:8080/`。`127.0.0.1` 既是安全上下文，也在 Service Worker 白名单里，因此**密码文件和离线缓存都能用**；但注意上游白名单写的是 `127.0.0.1`，不是 `localhost`。

## 7. 与上游同步

- 手动：GitHub fork 页面点 **Sync fork**（或本地 `git pull --rebase upstream main`）。
- 自动：Actions → **Sync with upstream** → Run workflow。它会 `fetch upstream/main`、`rebase`、push，然后手动触发一次 bundle 构建（用 `GITHUB_TOKEN` push 不会自动触发其他 workflow）。想每天自动检查，取消 `sync-upstream.yml` 里 `schedule` 两行的注释即可。
- 本 fork 的改动只有新增文件（打包脚本、两个 workflow、本文件），rebase 到上游新提交通常不会冲突；如果上游也改了 `.github/workflows/` 同名文件，冲突会停住而不会静默覆盖。

## 8. 安全与维护提示

- Release 产物是公开可下载的（fork 为公开仓库时）；里面只有上游本来就公开的静态站点代码，没有用户文件。
- 服务器更新脚本使用 `rsync --delete`，请确认 `WEB` 指向专用目录（例如 `/var/www/vibeoffice/site`），不要指向系统目录。
- 站点升级只是替换静态文件，不需要重启服务；HTTPS 证书和 nginx/Caddy 配置属于服务器侧，不在产物里。
- `updater/web-<version>.zip` 会随站点一起发布，大小约 5.4 MB；它只在 `https://vibeoffice.work` 或 `127.0.0.1` 上会被使用，内网域名下保留也无害。
