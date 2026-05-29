#!/bin/bash
# Relocate containerd's data root from /var (small, full) to /usr2 (large).
# Docker 29 uses the containerd image store, whose root is /var/lib/containerd and
# is NOT moved by Docker's data-root setting -- so image/build layers fill /var.
#
# Run with sudo:  sudo bash relocate_containerd.sh
# Safe: moves (not deletes) data; keeps a .old backup until you verify.
set -e

NEW_ROOT="/usr2/mingqia2/containerd-data"
OLD_ROOT="/var/lib/containerd"
CFG="/etc/containerd/config.toml"

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo."; exit 1; fi
echo "== Relocating containerd root: $OLD_ROOT -> $NEW_ROOT =="

echo "[1/7] Stopping docker + containerd..."
systemctl stop docker docker.socket 2>/dev/null || true
systemctl stop containerd

echo "[2/7] Creating new root dir..."
mkdir -p "$NEW_ROOT"

echo "[3/7] Moving data (~50GB, this takes a few minutes)..."
rsync -a --info=progress2 "$OLD_ROOT/" "$NEW_ROOT/"

echo "[4/7] Writing containerd config root=$NEW_ROOT..."
mkdir -p /etc/containerd
if [ ! -f "$CFG" ]; then
    containerd config default > "$CFG" 2>/dev/null || echo "" > "$CFG"
fi
if grep -qE '^\s*root\s*=' "$CFG"; then
    sed -i "s|^\s*root\s*=.*|root = \"$NEW_ROOT\"|" "$CFG"
else
    # prepend a top-level root setting
    sed -i "1i root = \"$NEW_ROOT\"" "$CFG"
fi
echo "    config root line:"; grep -E '^\s*root\s*=' "$CFG" | head -1

echo "[5/7] Backing up old root -> ${OLD_ROOT}.old (not deleted)..."
mv "$OLD_ROOT" "${OLD_ROOT}.old"

echo "[6/7] Starting containerd + docker..."
systemctl start containerd
systemctl start docker

echo "[7/7] Restarting server containers..."
docker start $(docker ps -aq) 2>/dev/null || true

echo ""
echo "== VERIFY =="
echo "containerd root in use:"
docker info 2>/dev/null | grep -iE "Docker Root Dir|Storage Driver" || true
echo "images present:"
docker images 2>/dev/null | head -6
echo "/var free now:"
df -h /var | tail -1
echo ""
echo "If images are listed and /var has ~50GB free, the move worked."
echo "Then reclaim space with:   sudo rm -rf ${OLD_ROOT}.old"
