#!/bin/bash
# Builds the aarch64 Omarchy disk for UTM SE inside a privileged Arch Linux ARM container.

set -euo pipefail

BUILDER=/builder
OUT=/out
WORK=/work
TARGET=$WORK/target
IMAGE=$WORK/omarchy.img
DISK_SIZE=32G
NODE_DIST_URL="https://nodejs.org/dist/latest"
PROVISIONING_DIR=var/lib/omarchy/provisioning
loop=""

cleanup() {
  umount -R "$TARGET" 2>/dev/null || true
  [[ -n $loop ]] && losetup -d "$loop" 2>/dev/null || true
}
trap cleanup EXIT

packages() {
  grep -hv '^#\|^$' "$1"
}

# Docker's /dev is static, so the partition nodes the kernel scanned have to be made by hand.
partition() {
  local node="${loop}p$1"
  [[ -b $node ]] || mknod "$node" b $(tr ':' ' ' <"/sys/block/${loop#/dev/}/${loop#/dev/}p$1/dev")
  echo "$node"
}

# The ISO defers the boot-image hooks the same way: /dev/null masks on the side pacman reads them from.
deferred_hooks=(60-mkinitcpio-remove.hook 60-limine-mkinitcpio-remove-pre.hook 80-limine-efi-deploy.hook 90-limine-mkinitcpio-remove-post.hook 90-mkinitcpio-install.hook)

mask_hooks() {
  local dir="$1" name path
  shift
  mkdir -p "$dir"
  for name in "$@"; do
    path="$dir/$name"
    if [[ -e $path || -L $path ]]; then
      mv "$path" "$path.omarchy-backup"
    fi
    ln -s /dev/null "$path"
  done
}

unmask_hooks() {
  local dir="$1" name path
  shift
  for name in "$@"; do
    path="$dir/$name"
    rm "$path"
    if [[ -e $path.omarchy-backup ]]; then
      mv "$path.omarchy-backup" "$path"
    fi
  done
}

chroot_env=(
  env --unset=XDG_RUNTIME_DIR
  OMARCHY_PATH=/usr/share/omarchy
  OMARCHY_INSTALL=/usr/share/omarchy/install
  OMARCHY_MIRROR=stable
  OMARCHY_RUNTIME_PACKAGE=omarchy-dev
  OMARCHY_SETTINGS_PACKAGE=omarchy-settings-dev
  OMARCHY_NVIM_PACKAGE=omarchy-nvim
  OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log
  OMARCHY_LOG_TO_STDOUT=1
)

echo "==> Preparing the build container"
pacman-key --init
pacman-key --populate archlinuxarm
install -m 0644 "$BUILDER/mirrorlist-utm-se" /etc/pacman.d/mirrorlist
pacman -Syu --noconfirm arch-install-scripts btrfs-progs dosfstools gptfdisk psmisc qemu-img

echo "==> Partitioning a $DISK_SIZE disk"
mkdir -p "$WORK" "$TARGET"
rm -f "$IMAGE"
truncate -s "$DISK_SIZE" "$IMAGE"
sgdisk --zap-all --new=1:0:+1G --typecode=1:ef00 --change-name=1:OMARCHY_ESP \
  --new=2:0:0 --typecode=2:8305 --change-name=2:OMARCHY "$IMAGE" >/dev/null
loop=$(losetup --find --show --partscan "$IMAGE")
esp=$(partition 1)
root=$(partition 2)

mkfs.vfat -F32 -n OMARCHY_ESP "$esp" >/dev/null
mkfs.btrfs -f -L OMARCHY "$root" >/dev/null
mount "$root" "$TARGET"
for subvolume in @ @home @log @pkg; do
  btrfs subvolume create "$TARGET/$subvolume" >/dev/null
done
umount "$TARGET"
mount -o noatime,compress=zstd,subvol=@ "$root" "$TARGET"
mkdir -p "$TARGET/home" "$TARGET/var/log" "$TARGET/var/cache/pacman/pkg" "$TARGET/boot"
mount -o noatime,compress=zstd,subvol=@home "$root" "$TARGET/home"
mount -o noatime,compress=zstd,subvol=@log "$root" "$TARGET/var/log"
mount -o noatime,compress=zstd,subvol=@pkg "$root" "$TARGET/var/cache/pacman/pkg"
mount "$esp" "$TARGET/boot"

echo "==> Installing the base system and Omarchy"
# pacstrap reads hooks from this container's /etc/pacman.d/hooks; the UKI is built once by limine-update at the end.
mask_hooks /etc/pacman.d/hooks "${deferred_hooks[@]}"
pacstrap -c -K -C "$BUILDER/pacman-utm-se.conf" "$TARGET" $(packages "$BUILDER/utm-se.packages")
base_list="$TARGET/usr/share/omarchy/install/omarchy-base.packages"
pacstrap -c -C "$BUILDER/pacman-utm-se.conf" "$TARGET" \
  $(bash "$TARGET/usr/bin/omarchy-pkg-list" "$base_list" | grep -vxF -f <(packages "$BUILDER/utm-se-drop.packages"))

echo "==> Configuring the system"
# genfstab falls back to the hand-made loop device names here, so the table is written from the UUIDs directly.
root_uuid=$(blkid -s UUID -o value "$root")
esp_uuid=$(blkid -s UUID -o value "$esp")
cat >"$TARGET/etc/fstab" <<FSTAB
UUID=$root_uuid /                     btrfs rw,noatime,compress=zstd,subvol=/@      0 0
UUID=$root_uuid /home                 btrfs rw,noatime,compress=zstd,subvol=/@home  0 0
UUID=$root_uuid /var/log              btrfs rw,noatime,compress=zstd,subvol=/@log   0 0
UUID=$root_uuid /var/cache/pacman/pkg btrfs rw,noatime,compress=zstd,subvol=/@pkg   0 0
UUID=$esp_uuid  /boot                 vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,errors=remount-ro 0 2
FSTAB
install -m 0644 "$BUILDER/pacman-utm-se.conf" "$TARGET/etc/pacman.conf"
install -m 0644 "$BUILDER/mirrorlist-utm-se" "$TARGET/etc/pacman.d/mirrorlist"
echo "en_US.UTF-8 UTF-8" >"$TARGET/etc/locale.gen"
arch-chroot "$TARGET" locale-gen >/dev/null
echo "LANG=en_US.UTF-8" >"$TARGET/etc/locale.conf"
printf 'KEYMAP=us\nXKBLAYOUT=us\n' >"$TARGET/etc/vconsole.conf"
echo omarchy >"$TARGET/etc/hostname"
ln -sf /usr/share/zoneinfo/UTC "$TARGET/etc/localtime"
install -m 0644 "$BUILDER/utm/monitors.lua" "$TARGET/etc/skel/.config/hypr/monitors.lua"

echo "==> Installing Limine on the fallback boot path"
# The virt machine's firmware puts the console on the serial port; tty0 keeps boot messages on the display too.
cmdline="root=UUID=$root_uuid rootflags=subvol=@ rw console=ttyAMA0 console=tty0"
install -D -m 0644 "$TARGET/usr/share/limine/BOOTAA64.EFI" "$TARGET/boot/EFI/BOOT/BOOTAA64.EFI"
mkdir -p "$TARGET/etc/kernel"
cat >"$TARGET/etc/pacman.d/hooks/99-omarchy-limine.hook" <<'HOOK'
[Trigger]
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Omarchy Limine after upgrade...
When = PostTransaction
Exec = /bin/sh -c "/usr/bin/cp /usr/share/limine/BOOTAA64.EFI /boot/EFI/BOOT/BOOTAA64.EFI"
HOOK
sed "s|@@CMDLINE@@|$cmdline|" "$TARGET/usr/share/omarchy/default/limine/default.conf" >"$TARGET/etc/default/limine"
echo "$cmdline" >"$TARGET/etc/kernel/cmdline"
cp "$TARGET/usr/share/omarchy/default/limine/limine.conf" "$TARGET/boot/limine.conf"

echo "==> Running Omarchy system setup"
mask_hooks "$TARGET/etc/pacman.d/hooks" 90-mkinitcpio-install.hook
arch-chroot "$TARGET" "${chroot_env[@]}" omarchy-apply-system --defer-provisioning --first-install
unmask_hooks "$TARGET/etc/pacman.d/hooks" 90-mkinitcpio-install.hook

echo "==> Staging first-boot provisioning"
provisioning="$TARGET/$PROVISIONING_DIR"
install -d -m 0755 "$provisioning" "$provisioning/packages"
shasums=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
node_file=$(awk '/linux-arm64\.tar\.gz$/ { print $2 }' <<<"$shasums")
curl -fsSL "$NODE_DIST_URL/$node_file" -o "$provisioning/packages/$node_file"
awk -v file="$provisioning/packages/$node_file" '/linux-arm64\.tar\.gz$/ { print $1 "  " file }' <<<"$shasums" | sha256sum -c - >/dev/null
touch "$provisioning/pending"
install -m 0644 "$TARGET/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service" \
  "$TARGET/etc/systemd/system/omarchy-provision-owner.service"
mkdir -p "$TARGET/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/omarchy-provision-owner.service \
  "$TARGET/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"

echo "==> Building the boot entries"
arch-chroot "$TARGET" limine-update
arch-chroot "$TARGET" btrfs quota disable / >/dev/null 2>&1 || true
# limine-update swallows a kernel's failure, so the UKI and its entry are checked directly.
compgen -G "$TARGET/boot/EFI/Linux/*.efi" >/dev/null
grep -q 'EFI/Linux/' "$TARGET/boot/limine.conf"

echo "==> Sealing the image"
version=$(arch-chroot "$TARGET" pacman -Q omarchy-dev | cut -d' ' -f2)
: >"$TARGET/etc/machine-id"
rm -f "$TARGET"/etc/ssh/ssh_host_* "$TARGET/root/.bash_history"
rm -rf "$TARGET"/var/cache/pacman/pkg/*
# Freed blocks still hold old bytes; trimming zeroes them so they compress to nothing.
fstrim "$TARGET" && fstrim "$TARGET/boot"

echo "==> Checking the sealed image"
[[ ! -s $TARGET/etc/machine-id ]]
[[ -z $(ls -A "$TARGET/var/cache/pacman/pkg") ]]
[[ -f $provisioning/pending && -f $provisioning/packages/$node_file ]]
[[ -L $TARGET/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service ]]
[[ -f $TARGET/boot/EFI/BOOT/BOOTAA64.EFI && -f $TARGET/etc/snapper/configs/root ]]
[[ -f $TARGET/etc/pacman.d/hooks/90-mkinitcpio-install.hook && ! -L $TARGET/etc/pacman.d/hooks/90-mkinitcpio-install.hook ]]
grep -q "root=UUID=$root_uuid" "$TARGET/etc/kernel/cmdline"
# Keyring setup leaves gpg-agents holding files on the target; their sockets died with the chroot's /run, so kill by holder.
fuser -km "$TARGET" >/dev/null 2>&1 || true
if ! umount -R "$TARGET"; then
  fuser -vm "$TARGET" || true
  exit 1
fi
losetup -d "$loop"
loop=""

echo "==> Writing the compressed disk"
qemu-img convert -c -O qcow2 -o compression_type=zstd,cluster_size=2M "$IMAGE" "$OUT/omarchy-utm-se.qcow2"
echo "$version" >"$OUT/omarchy-utm-se.version"
