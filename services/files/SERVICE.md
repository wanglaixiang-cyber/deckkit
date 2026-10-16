# 把 Steam Deck 的家目录共享给 Mac，Finder 侧边栏里多一个「deck」

NFS 为主通道（Finder 挂载，进侧边栏），rclone WebDAV 为回退通道。
共享的是 **Deck 家目录根** `/home/deck`，Mac 挂到 `/Volumes/deck`。

---

## 一句话用法

```bash
deck files status       # 现在什么情况
deck files mount        # 挂上（然后 Finder 侧边栏就有 deck 了）
deck files open         # 在访达里打开
```

---

## 目录

```
services/files/
├── SERVICE.md              ← 本文件
├── service                 ← 服务入口（被 bin/deck 转发）
├── mac/config.env          ← 共享目录、挂载点、客户端网段
└── deck/
    ├── provision-root.sh   ← 一次性 root 配置：起 NFS、写 /etc/exports
    └── rclone-webdav.service ← WebDAV 回退通道的用户级单元
```

---

## 常用命令

```bash
deck files status          # Deck 在线 / NFS 端口 / 导出 / 挂载 / WebDAV
deck files mount           # 挂载（走 Finder，所以会进侧边栏）
deck files unmount         # 卸载
deck files toggle          # 挂载 ↔ 卸载（菜单栏点一下走的就是它）
deck files ensure          # 幂等自愈：没挂上就挂上（正常时静默）
deck files open            # 访达打开挂载点
deck files url             # 打印 nfs:// 与 http:// 地址
deck files provision       # 在 Deck 上配置 NFS 导出（root，幂等）
deck files provision --revert   # 撤销 Deck 侧配置
deck files webdav install  # 安装/更新 WebDAV 单元并启动
deck files webdav on|off|status
```

**NFS 挂载会掉，这是常态**：Deck 休眠或重启后，Mac 这一侧的挂载点就没了；
实测 Deck **一直在线**时也可能自己掉（NFS 客户端超时等）。所以本服务实现了
`ensure`（幂等补挂），由菜单栏每轮刷新调用一次。走 Finder 的 `mount volume` 挂载，
所以补回来的挂载仍然会出现在访达侧边栏里。

**`ensure` 为什么不会和手动卸载打架**：本服务会记一个「期望状态」
（`~/Library/Application Support/deckkit/files.want`）：

| 你的动作 | 写入 | `ensure` 的行为 |
|---|---|---|
| `deck files mount` / 菜单栏点一下挂载 | `on` | 掉了就自动补挂 |
| `deck files unmount` / 菜单栏点一下卸载 | `off` | **不动手**，尊重你的选择 |

没有这个标记，每轮刷新都会把刚卸载的挂载又装回去 —— 手动操作永远不生效。

---

## 两条通道

| 通道 | 地址 | 特点 |
|---|---|---|
| **NFS**（主） | `nfs://steamdeck.local/home/deck` → `/Volumes/deck` | 快；走 Finder 挂载所以有侧边栏 |
| **WebDAV**（回退） | `http://steamdeck.local:8088` | NFS 被挡/挂不上时的备胎；不占侧边栏 |

### 为什么 NFS 优先

`nfs-utils` 是 SteamOS 官方预装包，不用解锁只读层、不用 `pacman`（一更新就没了）。
实测拿到 WiFi 上限吞吐。

### 为什么用 `mount volume` 而不是 `mount_nfs`

只有走 Finder 的 `mount volume`，卷才会出现在**访达侧边栏**里。
直接 `mount_nfs` 挂上去只是个普通挂载点。

---

## 参数（`mac/config.env`）

| 键 | 默认 | 说明 |
|---|---|---|
| `DECK_NFS_DIR` | `/home/deck` | Deck 上被共享的目录（要 root 重跑 provision 才生效） |
| `CLIENT_NET` | `10.0.0.0/24` | 允许访问的网段（写进 `/etc/exports`） |
| `MOUNT_POINT` | `/Volumes/deck` | 卷名取决于导出路径最后一段，改目录要同步改这里 |
| `WEBDAV_PORT` | `8088` | WebDAV 端口 |

---

## 已知注意点

- **`all_squash + anonuid=1000` 是必须的**：Mac 的 uid 是 501，不做映射的话
  Mac 写进去的文件在 Deck 上属主是 501，deck 用户自己反而改不动。
  现在的效果是 Mac 写入的文件在 Deck 上属主显示为 `deck`。
- **`/etc/exports` 在 overlay 上**：SteamOS 大版本更新会清掉，重跑
  `deck files provision` 即可。
- **陈旧挂载**：Deck 休眠时 NFS 挂载点会「挂着但无响应」，
  此时 `deck files unmount` 可能失败，需要 `sudo umount -f /Volumes/deck`。
  `deck files status` 会把它标成「已挂载但无响应」。
- **挂载前先探 2049**：对着没开 NFS 的主机调 `osascript` 会干等 40 多秒，
  所以 `mount` 先用 SSH 花 0.2 秒探端口。
- **共享的是整个家目录**：包括 `~/.ssh`、`~/apps` 等，注意别在 Mac 上误删。
  只想共享子目录就改 `DECK_NFS_DIR`。

- **NFS 属性缓存约 60 秒**：绕过 NFS 直接在 Deck 上写的文件，Mac 侧要过一会儿
  才看得见。别把它当成「没写进去」；重要判断前先 `stat` 一下。
- **AppleDouble**：macOS 往 NFS 写文件会顺带生成 `._xxx` 陪衬文件（内核写的，
  排除列表拦不住）。同步/校验清单时要扫掉，否则会被当成真文件。
