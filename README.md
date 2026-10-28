# Hister for 懒猫微服

把 [Hister](https://github.com/asciimoo/hister)（自建私人搜索引擎）打包成懒猫微服应用，
发布到喵喵商店（私有商店），使用**镜像模式**分发上游 Docker 镜像。

## 特性

- **免密登录**：懒猫网关在鉴权通过后下发 `X-HC-User-ID`，Hister 侧配置
  `server.proxy_auth_header` 直接采信，每个微服用户自动对应一个独立 Hister 账号，
  彼此的索引数据互相隔离。
- **镜像模式**：`ghcr.io/asciimoo/hister` 的镜像通过镜像加速地址分发，不占用
  懒猫官方镜像仓库配额。
- **自动创建管理员**：首次启动时生成一个管理员账号，随机密码写入
  `/lzcapp/var/hister-admin-password`。

## 管理员账号

Hister 没有"按角色映射管理员"的机制：经网关登录的用户一律是非管理员。因此
应用在 `setup_script` 阶段（容器启动前，以 root 执行）离线创建一个名为 `admin`
的管理员账号：

- 密码为随机生成（24 位字母数字），**不随安装包分发**；
- 密码写入容器内 `/lzcapp/var/hister-admin-password`，属主为 Hister 运行用户
  `65532`，权限 `0600`；
- 脚本是幂等的：数据库已存在时直接跳过，不会重置密码。

在微服里查看密码：

```sh
cat /lzcapp/var/hister-admin-password
```

用该账号名和密码登录 Hister 即可访问 `/api/users`、`/api/reindex`、
`/api/cleanup`、`/api/reload`、`/api/diagnostics` 等管理接口。

> 注意：普通微服用户若用户名恰好是 `admin`，经网关登录后拿到的也是这个
> 管理员账号。避免使用 `admin` 作为微服用户名。

### 为什么需要 ptyexec

Hister CLI 的 `hister user create --offline --admin` 用 bubbletea 弹出交互式密码
提示，而 bubbletea 要求进程拥有控制终端（`/dev/tty`）。容器里没有 TTY，直接
调用会失败：

```
failed to read password: bubbletea: error opening TTY: could not open TTY: open /dev/tty: no such device or address
```

`scripts/ptyexec` 是一个小工具：分配一个 PTY，把子进程设为该 PTY 的会话首进程
并挂上控制终端，然后按行喂入密码。它由 `scripts/build-content.sh` 静态编译进
LPK 的 content 目录。

## 目录结构

```text
.
├── lzc-build.yml            # 构建配置（manifest / contentdir / buildscript）
├── lzc-manifest.yml         # 应用清单
├── package.yml              # 应用元数据
├── icon.png
├── scripts/
│   ├── build-content.sh     # 构建脚本：交叉编译 ptyexec，拷贝 setup.sh
│   ├── setup.sh             # 管理员引导脚本（由 manifest 的 setup_script 调用）
│   └── ptyexec/             # PTY 包装器源码
└── .github/
    ├── lazycat-action.yml   # 懒猫发布 Action 配置
    └── workflows/lazycat.yml
```

## 本地构建

```sh
lzc-cli project build
```

产物在 `dist/` 下。

## 发布

`.github/workflows/lazycat.yml` 调用 `ca-x/lazycat-github-action`，在标签推送、
手动触发或定时任务时构建 LPK，并发布到喵喵商店。需要的仓库 Secrets：

```text
APPSTORE_URL
APPSTORE_TOKEN
APP_ID                 # 可选
PRIVATE_STORE_GROUP_CODES  # 可选
```

## 许可证

Hister 本体采用 AGPL-3.0-or-later，版权归上游作者所有。本仓库的打包代码同样
以 AGPL-3.0-or-later 发布。
