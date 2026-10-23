#!/bin/sh
# Makes a self-host bundle from public/, ready to copy to a web server:
#
#   tools/build-site-bundle.sh [OUT_DIR]        (default: dist/)
#
# The bundle is the published site of one version (tools/current-tree-version.sh):
#   site/                                  the content of public/ (the web root)
#   VERSION                                v<yyyy>.<mm>.<dd>-<6 hex>
#   build-info.json                        commit, ref, run, time
#   SHA256SUMS.site                        checksum of every file in site/
#   README-DEPLOY.txt                      how to install it
#   vibeoffice-site-<version>.tar.gz       site/, VERSION, build-info.json, SHA256SUMS.site, README-DEPLOY.txt
#   vibeoffice-site-<version>.zip          the same in a zip
#   vibeoffice-site.tar.gz / .zip          the same under a stable name (for the rolling release)
#   SHA256SUMS                             checksums of the two packages
#
# site/ is stamped by tools/web-release.sh: the version goes into common/suite.js and sw.js, and
# updater/web-<version>.zip is packed. On an origin other than https://vibeoffice.work or 127.0.0.1 the
# service worker is disabled (docs/suite.md), so the zip is only useful there or with a patched origin;
# it does no harm when it is served.
#
# Needs git, zip (Info-ZIP) and a sha256 tool, all on the CI runner and on a normal dev machine.
# The build is pure file copying: no Node.js or Python is needed to serve the result.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=${1:-$ROOT/dist}

case "$OUT" in
  "" | "/" | "$ROOT" | "$ROOT/public")
    echo "Refusing to build into $OUT" >&2
    exit 1
    ;;
esac
case "$OUT" in
  /*) ;;
  *) OUT=$PWD/$OUT ;;
esac

for cmd in git zip tar find cp; do
  command -v "$cmd" > /dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
if command -v sha256sum > /dev/null 2>&1; then
  SHA="sha256sum"
elif command -v shasum > /dev/null 2>&1; then
  SHA="shasum -a 256"
else
  echo "Missing a SHA-256 tool (sha256sum or shasum -a 256)" >&2
  exit 1
fi

VERSION=$("$ROOT/tools/current-tree-version.sh")
COMMIT=$(git -C "$ROOT" rev-parse HEAD)
SHORT=$(git -C "$ROOT" rev-parse --short=6 HEAD)
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REF=${GITHUB_REF_NAME:-$(git -C "$ROOT" branch --show-current 2>/dev/null || echo unknown)}
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  REPOSITORY=https://github.com/$GITHUB_REPOSITORY
else
  REPOSITORY=$(git -C "$ROOT" remote get-url origin 2>/dev/null || echo unknown)
fi
RUN_ID=${GITHUB_RUN_ID:-local}

rm -rf "$OUT"
mkdir -p "$OUT/site"
cp -a "$ROOT/public/." "$OUT/site/"
# a stale update zip from an earlier local build must not travel in the new one
rm -f "$OUT"/site/updater/web-*.zip

"$ROOT/tools/web-release.sh" "$OUT/site" "$VERSION"

printf '%s\n' "$VERSION" > "$OUT/VERSION"

{
  printf '{\n'
  printf '  "version": "%s",\n' "$VERSION"
  printf '  "commit": "%s",\n' "$COMMIT"
  printf '  "commit_short": "%s",\n' "$SHORT"
  printf '  "ref": "%s",\n' "$REF"
  printf '  "repository": "%s",\n' "$REPOSITORY"
  printf '  "run_id": "%s",\n' "$RUN_ID"
  printf '  "built_at": "%s",\n' "$BUILT_AT"
  printf '  "built_by": "tools/build-site-bundle.sh"\n'
  printf '}\n'
} > "$OUT/build-info.json"

# every file of the site, so an installation can be checked after unpacking
(cd "$OUT" && find site -type f | LC_ALL=C sort | while IFS= read -r f; do $SHA "$f"; done > SHA256SUMS.site)

cat > "$OUT/README-DEPLOY.txt" <<EOF
VibeOffice 自托管静态站点发布包
==============================

版本:      $VERSION
提交:      $COMMIT
构建时间:  $BUILT_AT
来源:      $REPOSITORY

内容
----
  site/              网站的根目录（即仓库 public/ 的内容，已写入版本号）
  VERSION            版本号
  build-info.json    构建信息
  SHA256SUMS.site    site/ 中每个文件的 SHA-256
  SHA256SUMS         带版本号的两个发布包的 SHA-256
  SHA256SUMS.latest  稳定命名副本（vibeoffice-site.tar.gz/.zip）的 SHA-256

安装（Linux + nginx/Caddy，web root 以 /var/www/vibeoffice/site 为例）
--------------------------------------------------------------------
  tar -xzf vibeoffice-site-$VERSION.tar.gz
  sudo rsync -a --delete site/ /var/www/vibeoffice/site/
  sudo chown -R root:root /var/www/vibeoffice/site
  sudo find /var/www/vibeoffice/site -type d -exec chmod 755 {} +
  sudo find /var/www/vibeoffice/site -type f -exec chmod 644 {} +
  sudo nginx -t && sudo systemctl reload nginx     # 或: sudo systemctl reload caddy

  校验（可选但推荐）：
  (cd 解包后的目录 && sha256sum -c SHA256SUMS.site)

说明
----
* 站点是纯静态文件，没有后端，也不需要 Node/Python 运行环境。
* 必须通过 HTTPS 访问（或 127.0.0.1）：密码保护的 Office 文件依赖 WebCrypto。
* 自签证书（浏览器不信任）不会得到安全上下文：此时 WebCrypto 和 Service Worker
  不可用；页面仍可打开和编辑普通文件。先把自签 CA 装进客户端信任库即可恢复 WebCrypto。
* Service Worker/离线缓存只在 https://vibeoffice.work 和 127.0.0.1 上启用（上游代码写死），
  内网域名/IP 访问时即使证书受信任也不会离线。updater/web-$VERSION.zip 可保留，不影响使用。
* 升级就是替换 site/ 的内容；不要删除 updater/（回滚到旧包时需要）。
EOF

tar -C "$OUT" -czf "$OUT/vibeoffice-site-$VERSION.tar.gz" \
  site VERSION build-info.json SHA256SUMS.site README-DEPLOY.txt
(cd "$OUT" && zip -qr "vibeoffice-site-$VERSION.zip" \
  site VERSION build-info.json SHA256SUMS.site README-DEPLOY.txt)

(cd "$OUT" && $SHA "vibeoffice-site-$VERSION.tar.gz" "vibeoffice-site-$VERSION.zip" > SHA256SUMS)
cp "$OUT/vibeoffice-site-$VERSION.tar.gz" "$OUT/vibeoffice-site.tar.gz"
cp "$OUT/vibeoffice-site-$VERSION.zip" "$OUT/vibeoffice-site.zip"
(cd "$OUT" && $SHA "vibeoffice-site.tar.gz" "vibeoffice-site.zip" > SHA256SUMS.latest)

printf 'Built %s\n' "$VERSION"
printf '  %s\n' "$OUT/site"
printf '  %s (%s)\n' "$OUT/vibeoffice-site-$VERSION.tar.gz" "$(du -h "$OUT/vibeoffice-site-$VERSION.tar.gz" | cut -f1)"
printf '  %s (%s)\n' "$OUT/vibeoffice-site-$VERSION.zip" "$(du -h "$OUT/vibeoffice-site-$VERSION.zip" | cut -f1)"
printf '  %s\n' "$OUT/SHA256SUMS"
