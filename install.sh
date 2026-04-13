#!/usr/bin/env bash
set -euo pipefail

# =========================
# User-configurable values
# =========================
DISK="${DISK:-/dev/sda}"
HOSTNAME="${HOSTNAME:-archvm}"
USERNAME="${USERNAME:-user}"
USER_PASSWORD="${USER_PASSWORD:-changeme}"
ROOT_PASSWORD="${ROOT_PASSWORD:-rootchangeme}"
TIMEZONE="${TIMEZONE:-Europe/Dublin}"
EFI_SIZE="${EFI_SIZE:-1GiB}"

# =========================
# Safety checks
# =========================
if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root from the Arch ISO."
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Disk $DISK does not exist."
  lsblk
  exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
  echo "This script assumes the Arch ISO was booted in UEFI mode."
  echo "In VirtualBox, enable EFI and boot the ISO again."
  exit 1
fi

echo "About to ERASE and install Arch Linux on $DISK"
sleep 5

# =========================
# Time sync
# =========================
timedatectl set-ntp true

# =========================
# Partitioning
# Layout:
#   1 = EFI
#   2 = root
# =========================
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
partprobe "$DISK" || true
udevadm settle

# Fresh GPT
sgdisk -o "$DISK"

# EFI partition
sgdisk -n 1:1MiB:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI" "$DISK"

# Root partition: use remaining usable space automatically
sgdisk -N 2 -t 2:8300 -c 2:"root" "$DISK"

partprobe "$DISK" || true
udevadm settle
sleep 2

# Handle naming for SATA vs NVMe/MMC
if [[ "$DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

# Sanity check
if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
  echo "Partition devices not found."
  lsblk
  exit 1
fi

# =========================
# Filesystems
# =========================
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"

mount "$ROOT_PART" /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# =========================
# Base system install
# =========================
pacstrap -K /mnt \
  base \
  base-devel \
  linux \
  linux-headers \
  linux-firmware \
  grub \
  efibootmgr \
  networkmanager \
  sudo \
  nano \
  vim \
  git \
  curl \
  wget \
  man-db \
  man-pages \
  texinfo \
  dosfstools \
  mtools \
  bash-completion \
  xdg-user-dirs \
  xdg-utils \
  pipewire \
  pipewire-alsa \
  pipewire-audio \
  pipewire-jack \
  pipewire-pulse \
  wireplumber \
  alsa-utils \
  sof-firmware \
  rtkit \
  zram-generator \
  plasma-meta \
  plasma-x11-session \
  kde-applications-meta \
  sddm \
  xorg \
  xorg-server \
  xorg-xinit \
  virtualbox-guest-utils \
  virtualbox-guest-iso

genfstab -U /mnt >> /mnt/etc/fstab

# =========================
# System configuration
# =========================
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Time
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale generation
sed -i 's/^#\\s*en_IE.UTF-8 UTF-8/en_IE.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# Locale settings matching your NixOS config
cat > /etc/locale.conf <<LOCALECONF
LANG=en_IE.UTF-8
LC_ADDRESS=en_IE.UTF-8
LC_IDENTIFICATION=en_IE.UTF-8
LC_MEASUREMENT=en_IE.UTF-8
LC_MONETARY=en_IE.UTF-8
LC_NAME=en_IE.UTF-8
LC_NUMERIC=en_IE.UTF-8
LC_PAPER=en_IE.UTF-8
LC_TELEPHONE=en_IE.UTF-8
LC_TIME=en_IE.UTF-8
LOCALECONF

# Console keymap
cat > /etc/vconsole.conf <<VCONSOLE
KEYMAP=ie
VCONSOLE

# Hostname and hosts
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# zram swap
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<ZRAMCONF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMCONF

# Root password
echo "root:${ROOT_PASSWORD}" | chpasswd

# User
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Optional localectl setup
localectl set-locale LANG=en_IE.UTF-8 || true
localectl set-keymap ie || true

# Services
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable vboxservice

# Initramfs
mkinitcpio -P

# GRUB
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg
EOF

# =========================
# Install paru and Google Chrome
# Done after the main chroot setup
# =========================
arch-chroot /mnt /bin/bash -c "su - ${USERNAME} -c '
set -e
cd ~
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
'"

arch-chroot /mnt /bin/bash -c "su - ${USERNAME} -c '
set -e
paru -S --noconfirm google-chrome
'"

echo
echo "Install complete."
echo
echo "Now run:"
echo "  umount -R /mnt"
echo "  reboot"
