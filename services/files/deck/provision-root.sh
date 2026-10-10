#!/usr/bin/env bash
# ============================================================
#  deckkit / files —— Deck 侧 root 配置（一次性，幂等）
#
#  做两件事：
#    1. 启用 NFS 服务端（nfs-utils 官方预装，不用解锁只读层）
#    2. 把 Deck 家目录导出给局域网
#
#  全部落在 overlay 上，SteamOS 大版本更新后可能被清掉 —— 重跑本脚本即可。
#
#    bash provision-root.sh              配置
#    bash provision-root.sh --revert     撤销（停 NFS、删 /etc/exports）
#    bash provision-root.sh --powersave  额外持久关闭 WiFi 省电（默认不动）
# ============================================================
set -uo pipefail

EXPORT_DIR="${DECK_NFS_DIR:-$HOME}"
CLIENT_NET="${DECK_NFS_NET:-10.0.0.0/24}"
NM_CONF="/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf"

ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }

sudo -n true 2>/dev/null || die "没有免密 sudo。先在 Deck 的 Konsole 里执行：
    echo \"deck ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/zz-deck-nopasswd >/dev/null
    sudo chmod 440 /etc/sudoers.d/zz-deck-nopasswd"

# ---------------- 撤销 ----------------
if [ "${1:-}" = "--revert" ]; then
  step "撤销"
  sudo rm -f /etc/exports && ok "/etc/exports 已删除"
  sudo exportfs -ra 2>/dev/null
  sudo systemctl disable --now nfs-server 2>/dev/null && ok "NFS 已停用"
  sudo rm -f "$NM_CONF" && ok "WiFi 省电配置已删除"
  sudo systemctl reload NetworkManager 2>/dev/null
  echo "  （rpcbind 保留：其他服务可能也在用）"
  exit 0
fi

step "1/3  WiFi 省电"
# 默认不动：Deck 常用于挂机游戏，省电模式对续航有意义。
if [ "${1:-}" = "--powersave" ]; then
  echo "  改前: $(iw dev wlan0 get power_save 2>&1)"
  sudo iw dev wlan0 set power_save off 2>/dev/null && ok "运行时已关闭"
  sudo mkdir -p "$(dirname "$NM_CONF")"
  printf '[connection]\nwifi.powersave = 2\n' | sudo tee "$NM_CONF" >/dev/null
  ok "已写 ${NM_CONF}（重启后仍生效）"
else
  echo "  跳过（保持 $(iw dev wlan0 get power_save 2>&1 | awk '{print $NF}')）"
  echo "  想持久关闭：bash $0 --powersave"
fi

step "2/3  启用 NFS 服务端"
sudo systemctl enable --now rpcbind.socket rpcbind.service >/dev/null 2>&1
sudo systemctl enable --now nfs-server.service >/dev/null 2>&1
sleep 1
printf '  nfs-server: %s\n' "$(systemctl is-active nfs-server)"
printf '  rpcbind   : %s\n' "$(systemctl is-active rpcbind)"
systemctl is-active nfs-server >/dev/null || die "nfs-server 没起来，看 journalctl -u nfs-server"

step "3/3  导出 $EXPORT_DIR"
[ -d "$EXPORT_DIR" ] || die "导出目录不存在：$EXPORT_DIR"
# all_squash + anonuid=1000：Mac（uid 501）的写入全映射成 deck，
# 否则 NFS 按原始 uid 落盘，Mac 写进来的文件 deck 自己反而改不动。
# insecure：允许客户端用 >1024 的源端口（macOS 客户端常见）。
sudo tee /etc/exports >/dev/null <<EOF
# Steam Deck 家目录共享 —— 由 deckkit/files 的 provision-root.sh 生成
# 撤销：bash provision-root.sh --revert
$EXPORT_DIR  $CLIENT_NET(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000,insecure)
EOF
ok "已写 /etc/exports"
sudo exportfs -ra 2>&1 | sed 's/^/  /'
echo "  --- 当前导出 ---"
sudo exportfs -v 2>/dev/null | sed 's/^/  /'

if systemctl is-active firewalld >/dev/null 2>&1; then
  warn "firewalld 在跑，放行 NFS"
  sudo firewall-cmd --permanent --add-service=nfs >/dev/null 2>&1
  sudo firewall-cmd --permanent --add-service=mountd >/dev/null 2>&1
  sudo firewall-cmd --permanent --add-service=rpc-bind >/dev/null 2>&1
  sudo firewall-cmd --reload >/dev/null 2>&1
  ok "已放行"
fi

echo
ok "完成。Mac 侧挂载："
echo "     deck files mount"
echo "     或 Finder cmd+K → nfs://$(hostname 2>/dev/null || echo steamdeck.local)${EXPORT_DIR}"
