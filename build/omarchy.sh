#!/bin/bash
# Omarchy: Arch Linux ARM with Omarchy's Hyprland desktop, shell and apps,
# from Omarchy's own repositories. Its edge channel is the only one with
# aarch64 packages (as omarchy-dev).
#
#     build/omarchy.sh OUT
#
# Installed the way Omarchy's ISO and factory images install it: pacstrap base,
# linux-omarchy, omarchy-dev and the aarch64 default set, then run Omarchy's
# system setup while the image manifest makes it defer hardware-specific work.
# That queue runs on the machine's first boot, before its display manager. The
# owner is made by cloud-init and finalized by vendor-data/omarchy.yaml. The
# repository key in omarchy/ is Omarchy's, from omacom-io/omarchy-pkgs
# (fingerprint 40DFB630FF42BCFFB047046CF0134EE680CAC571).
set -euo pipefail
. "$(dirname "$0")/lib.sh"

out="$1"
work=/var/tmp/omarchy
builder="$work/builder"   # an Arch userland to build from
T="$builder/target"       # the system being built, /target in the builder
rm -rf "$work"
mkdir -p "$builder"

arch_rootfs "$builder" "$work"
in_root "$builder" pacman -S --noconfirm --needed arch-install-scripts btrfs-progs
cp "$LIB_DIR"/omarchy/omarchy.gpg "$LIB_DIR"/omarchy/omarchy-trusted "$LIB_DIR"/omarchy/omarchy-revoked \
    "$builder/usr/share/pacman/keyrings/"
in_root "$builder" pacman-key --populate omarchy

# Omarchy's aarch64 edge repositories (its pacman-edge.conf).
cat > "$builder/etc/pacman-omarchy.conf" <<'EOF'
[options]
HoldPkg = pacman glibc
Architecture = aarch64
ParallelDownloads = 8
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
DisableSandbox

[omarchy]
Server = https://pkgs.omarchy.org/edge/$arch

[core]
Server = https://arm-mirror.omarchy.org/$arch/$repo

[extra]
Server = https://arm-mirror.omarchy.org/$arch/$repo

[alarm]
Server = https://arm-mirror.omarchy.org/$arch/$repo

[aur]
Server = https://arm-mirror.omarchy.org/$arch/$repo
EOF
in_root "$builder" pacman --config /etc/pacman-omarchy.conf -Syy --noconfirm

# One initramfs build at the end rather than one per transaction: pacstrap
# runs the builder's hooks.
mkdir -p "$builder/etc/pacman.d/hooks"
ln -sfn /dev/null "$builder/etc/pacman.d/hooks/60-mkinitcpio-remove.hook"
ln -sfn /dev/null "$builder/etc/pacman.d/hooks/90-mkinitcpio-install.hook"

mkdir -p "$T/etc/pacman.d"
in_root "$builder" pacman-key --gpgdir /target/etc/pacman.d/gnupg --init
in_root "$builder" pacman-key --gpgdir /target/etc/pacman.d/gnupg --populate archlinuxarm omarchy
install_pkgs() { in_root "$builder" pacstrap -C /etc/pacman-omarchy.conf -G -M -c /target --needed "$@"; }

install_pkgs base linux-omarchy mkinitcpio
install_pkgs base-devel git omarchy-keyring archlinuxarm-keyring omarchy-settings-dev
install_pkgs lua51 luarocks
install_pkgs omarchy-nvim
install_pkgs omarchy-dev
mapfile -t defaults < <(in_root "$builder" arch-chroot /target env OMARCHY_PATH=/usr/share/omarchy \
    /usr/bin/omarchy-pkg-defaults aarch64)
[ "${#defaults[@]}" -gt 0 ] || { echo "omarchy: no default packages" >&2; exit 1; }
available=()
for name in "${defaults[@]}"; do
    if in_root "$builder" pacman --config /etc/pacman-omarchy.conf -Sp --print-format x "$name" >/dev/null 2>&1; then
        available+=("$name")
    else
        echo "omarchy: $name isn't available for aarch64"
    fi
done
# Snapper because Omarchy's system setup configures it and stops without it;
# btrfs-progs also grows crate's partitionless filesystem on first boot.
install_pkgs "${available[@]}" snapper cloud-init btrfs-progs

# --- system ---------------------------------------------------------------------
uuid=$(cat /proc/sys/kernel/random/uuid)
opts=noatime,compress=zstd
cat > "$T/etc/fstab" <<EOF
UUID=$uuid  /                      btrfs  rw,$opts,subvol=/@     0 0
UUID=$uuid  /home                  btrfs  rw,$opts,subvol=/@home 0 0
UUID=$uuid  /var/log               btrfs  rw,$opts,subvol=/@log  0 0
UUID=$uuid  /var/cache/pacman/pkg  btrfs  rw,$opts,subvol=/@pkg  0 0
EOF
echo omarchy > "$T/etc/hostname"
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$T/etc/locale.gen"
in_root "$builder" arch-chroot /target locale-gen
echo 'LANG=en_US.UTF-8' > "$T/etc/locale.conf"
printf 'KEYMAP=us\nXKBLAYOUT=us\n' > "$T/etc/vconsole.conf"
ln -sfn /usr/share/zoneinfo/UTC "$T/etc/localtime"

# Mark this as an image before system setup. Omarchy will configure everything
# independent of hardware now, queue the hardware leaves, and arm its service
# to run them on the actual machine before the first login screen.
install -d -m 0755 "$T/var/lib/omarchy/image"
printf 'format=1\nplatform=aarch64\nbuilder=image\nchannel=edge\n' > "$T/var/lib/omarchy/image/target"

# The staging tree is not Btrfs until it is packed below. Prevent Snapper's
# system setup from trying to create a Btrfs subvolume in the builder's
# overlay; crate-grow-root creates the real subvolume on the first boot.
install -d -m 0755 "$T/etc/snapper/configs" "$T/.snapshots"
: > "$T/etc/snapper/configs/root"

in_root "$builder" arch-chroot /target env \
    OMARCHY_PATH=/usr/share/omarchy \
    OMARCHY_INSTALL=/usr/share/omarchy/install \
    OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log \
    OMARCHY_LOG_TO_STDOUT=1 \
    /usr/bin/omarchy-apply-system --defer-provisioning --first-install

for unit in cloud-init-main cloud-init-local cloud-init-network cloud-init cloud-config cloud-final; do
    [ -e "$T/usr/lib/systemd/system/$unit.service" ] && in_root "$builder" arch-chroot /target systemctl enable "$unit.service"
done
in_root "$builder" arch-chroot /target systemctl enable sddm.service
in_root "$builder" arch-chroot /target systemctl set-default graphical.target
# SDDM waits for Omarchy's setup of the owner, which cloud-init runs last.
mkdir -p "$T/etc/systemd/system/sddm.service.d"
printf '[Unit]\nAfter=cloud-final.service\n' > "$T/etc/systemd/system/sddm.service.d/after-owner-setup.conf"

# Omarchy's own repositories, with the kernel held: it's booted from outside.
templates="$T/usr/share/omarchy/default/pacman/aarch64"
install -m 0644 "$templates/pacman-edge.conf" "$T/etc/pacman.conf"
install -m 0644 "$templates/mirrorlist-edge" "$T/etc/pacman.d/mirrorlist"
if grep -q '^#\?IgnorePkg' "$T/etc/pacman.conf"; then
    sed -i 's/^#\?IgnorePkg *=.*/IgnorePkg = linux-omarchy linux-omarchy-headers/' "$T/etc/pacman.conf"
else
    sed -i '/^\[options\]/a IgnorePkg = linux-omarchy linux-omarchy-headers' "$T/etc/pacman.conf"
fi
ln -sfn ../run/systemd/resolve/stub-resolv.conf "$T/etc/resolv.conf"
common_rootfs "$T"

# crate expands the raw disk sparsely to the size selected during install.
# Btrfs otherwise keeps the smaller size it had when this artifact was built.
# Resize on every boot so a later disk expansion is picked up as well; at the
# current size this is an inexpensive no-op. The image's empty .snapshots
# directory becomes a Btrfs subvolume before Snapper can use it.
install -d -m 0755 "$T/usr/local/sbin"
cat > "$T/usr/local/sbin/crate-prepare-btrfs" <<'EOF'
#!/bin/sh
set -eu

/usr/bin/btrfs filesystem resize max /
if ! /usr/bin/btrfs subvolume show /.snapshots >/dev/null 2>&1; then
    if [ -d /.snapshots ]; then
        rmdir /.snapshots
    fi
    /usr/bin/btrfs subvolume create /.snapshots
fi
EOF
chmod 0755 "$T/usr/local/sbin/crate-prepare-btrfs"

cat > "$T/etc/systemd/system/crate-grow-root.service" <<'EOF'
[Unit]
Description=Prepare Omarchy's Btrfs filesystem for crate
After=local-fs.target
Before=cloud-init-main.service cloud-init.service cloud-final.service omarchy-provision-hardware.service display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/crate-prepare-btrfs

[Install]
WantedBy=multi-user.target
EOF
in_root "$builder" arch-chroot /target systemctl enable crate-grow-root.service

# --- kernel and initrd -------------------------------------------------------------
# linux-omarchy is a plain arm64 Image with virtio and btrfs built in, so the
# initrd only has to mount /dev/vda: mkinitcpio's base hook alone.
kver=$(basename "$(dirname "$(ls "$T"/usr/lib/modules/*/pkgbase | head -1)")")
mkdir -p "$T/etc/mkinitcpio.conf.d"
cat > "$T/etc/mkinitcpio-vm.conf" <<'EOF'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base)
COMPRESSION="zstd"
EOF
cat > "$T/etc/mkinitcpio.d/linux-omarchy.preset" <<EOF
# The machine boots the kernel and initrd shipped beside the disk, not /boot.
ALL_kver="/usr/lib/modules/$kver/vmlinuz"
PRESETS=('default')
default_config="/etc/mkinitcpio-vm.conf"
default_image="/boot/initramfs-linux-omarchy.img"
EOF
in_root "$builder" arch-chroot /target mkinitcpio -k "$kver" -c /etc/mkinitcpio-vm.conf -g /root/vm-initrd.img
mv "$T/root/vm-initrd.img" "$work/initrd.img"
normalize_kernel "$T/usr/lib/modules/$kver/vmlinuz" "$work/vmlinuz"

# --- seal ----------------------------------------------------------------------------
# No identity shared between machines: Omarchy's first boot makes the pacman
# keyring, as its image target asks.
rm -f "$T/var/lib/systemd/random-seed"
rm -rf "$T/etc/pacman.d/gnupg" "$T/root/.cache" "$T/var/tmp/"*
find "$T/var/cache/pacman/pkg" -mindepth 1 -delete

# --- pack ------------------------------------------------------------------------------
# btrfs with Omarchy's subvolumes, @ the default so root=/dev/vda mounts it,
# made straight from a staging tree laid out as the subvolumes.
stage="$builder/stage"
mkdir -p "$stage"
mv "$T" "$stage/@"
mkdir -p "$stage/@home" "$stage/@log" "$stage/@pkg"
for pair in home:@home var/log:@log var/cache/pacman/pkg:@pkg; do
    from="$stage/@/${pair%%:*}" to="$stage/${pair##*:}"
    find "$from" -mindepth 1 -maxdepth 1 -exec mv -t "$to" {} +
done
rm -f "$work/disk.img"
truncate -s 64G "$builder/disk.img"
in_root "$builder" mkfs.btrfs -q -L root -U "$uuid" --rootdir /stage \
    --subvol default:@ --subvol rw:@home --subvol rw:@log --subvol rw:@pkg \
    --compress zstd:3 --shrink /disk.img
mv "$builder/disk.img" "$work/disk.img"
rm -rf "$builder"

package_image "$work" "$out" omarchy "Omarchy" "$(date -u +%Y.%m.%d)" "Hyprland" \
    "console=ttyAMA0 root=/dev/vda rw"
