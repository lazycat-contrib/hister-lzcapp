#!/bin/sh
# 构建打包进 LPK 的辅助文件。
#
# lzc-build.yml 的 buildscript 会在打包前调用本脚本, 把 scripts/ 下的内容
# 放到 contentdir 指定的目录, 供 manifest 通过 /lzcapp/pkg/content 挂载引用。
#
# 产物:
#   content/ptyexec      静态编译的 PTY 包装器 (供 setup.sh 驱动交互式密码提示)
#   content/setup.sh     管理员引导脚本

set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SRC_DIR/.." && pwd)"
OUT_DIR="${1:-$PROJECT_DIR/content}"
# 之后会 cd 到别处, 所以这里把输出目录转成绝对路径。
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# 目标架构由 CI 传入的 LAZYCAT_TARGET_ARCH 决定, 本地构建时回退到 amd64。
TARGET_ARCH="${LAZYCAT_TARGET_ARCH:-${TARGETARCH:-amd64}}"
case "$TARGET_ARCH" in
    amd64) GOARCH=amd64 ;;
    arm64) GOARCH=arm64 ;;
    *) echo "unsupported target arch: $TARGET_ARCH" >&2; exit 1 ;;
esac

GO="${GO:-go}"
if ! command -v "$GO" >/dev/null 2>&1; then
    echo "go toolchain not found" >&2
    exit 1
fi

cd "$SRC_DIR/ptyexec"
CGO_ENABLED=0 GOOS="${LAZYCAT_TARGET_OS:-linux}" GOARCH="$GOARCH" \
    "$GO" build -trimpath -ldflags "-s -w" -o "$OUT_DIR/ptyexec" .

cp "$SRC_DIR/setup.sh" "$OUT_DIR/setup.sh"
chmod +x "$OUT_DIR/setup.sh" "$OUT_DIR/ptyexec"

echo "built content into $OUT_DIR"
