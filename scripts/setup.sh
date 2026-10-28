#!/bin/sh
# Hister 管理员引导脚本
#
# 由懒猫微服在容器启动前以 root 身份执行 (manifest 的 setup_script 字段)。
# 之后 lzcos 会照常执行镜像原本的 entrypoint (hister listen)。
#
# 背景: Hister 的免密登录依赖懒猫网关下发的 X-HC-User-ID 头, 网关在鉴权成功后
# 注入真实用户名。但通过网关创建出来的账号一律是非管理员, 而 Hister 自身没有
# "按角色映射管理员" 的机制。所以这里在首次启动时离线创建一个管理员账号,
# 供需要管理接口 (用户管理/重建索引/清理/诊断) 的场景使用。
#
# 密码: 随机生成, 写入 /lzcapp/var/hister-admin-password, 不随安装包分发。
# 该文件属主为 Hister 运行用户, 只有能在微服里读文件的人才能拿到密码。
#
# 幂等: 每次容器启动都会执行本脚本, 因此必须保证重复执行不产生副作用。
# 已存在管理员账号时直接跳过, 不会重置密码。

set -e

DATA_DIR=/hister/data
ADMIN_USER=admin
PASSWORD_FILE=/lzcapp/var/hister-admin-password
PW_INPUT=/tmp/hister-pw-input
# Hister 进程的用户。setup_script 以 root 运行, 但 Hister 自己以这个身份运行,
# 所以数据目录里的文件必须属于它, 否则运行时会因权限不足而启动失败。
HISTER_UID=65532
HISTER_GID=65532

mkdir -p /lzcapp/var
chown "$HISTER_UID:$HISTER_GID" /lzcapp/var 2>/dev/null || true

# 数据库已存在说明不是首次启动, 直接跳过。
if [ -f "$DATA_DIR/db.sqlite3" ]; then
    exit 0
fi

# 生成随机密码 (base64 取前 24 字符, 去掉会干扰 shell 的字符)。
random_password() {
    head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24
}

PASSWORD="$(random_password)"
if [ "${#PASSWORD}" -lt 8 ]; then
    echo "hister setup: failed to generate a password" >&2
    exit 1
fi

# bubbletea 的密码提示需要两次输入 (密码 + 确认), 每行一条。
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" > "$PW_INPUT"
chmod 600 "$PW_INPUT"

# 数据目录需要 Hister 运行用户可写, 否则它建不了 .secret_key 和数据库。
chown "$HISTER_UID:$HISTER_GID" "$DATA_DIR" 2>/dev/null || true
chmod 755 "$DATA_DIR" 2>/dev/null || true

# 离线创建管理员。--offline 直接写数据库, 不需要服务已在运行。
# ptyexec 为命令分配伪终端, 使 bubbletea 的交互式提示得以完成。
#
# 以 Hister 的运行身份执行: setup_script 是 root, 若以 root 建库, 生成的
# .secret_key / db.sqlite3 属主会是 root, 之后 Hister 进程 (65532) 读不了
# 自己的密钥而启动失败。-u 让 ptyexec 在启动子进程前切换身份。
if ! /lzcapp/pkg/content/ptyexec -u "$HISTER_UID:$HISTER_GID" \
        "$PW_INPUT" /hister/hister \
        user create --offline --admin "$ADMIN_USER"; then
    echo "hister setup: failed to create the administrator account" >&2
    rm -f "$PW_INPUT"
    exit 1
fi

rm -f "$PW_INPUT"

# 兜底: 确认数据目录里的文件属主正确。
chown -R "$HISTER_UID:$HISTER_GID" "$DATA_DIR" 2>/dev/null || true

# 把密码落盘, 供管理员查看。
umask 077
printf '%s\n' "$PASSWORD" > "$PASSWORD_FILE"
chown "$HISTER_UID:$HISTER_GID" "$PASSWORD_FILE" 2>/dev/null || true
chmod 600 "$PASSWORD_FILE"

echo "hister setup: administrator '$ADMIN_USER' created, password stored in $PASSWORD_FILE"
