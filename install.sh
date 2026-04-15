#!/usr/bin/env bash
set -euo pipefail

# =========================
# User-configurable values
# =========================
DISK="${DISK:-/dev/sda}"
HOSTNAME="${HOSTNAME:-arch}"
USERNAME="${USERNAME:-user}"
USER_PASSWORD="${USER_PASSWORD:-changeme}"
ROOT_PASSWORD="${ROOT_PASSWORD:-changeme}"
TIMEZONE="${TIMEZONE:-Europe/Dublin}"
EFI_SIZE="${EFI_SIZE:-1GiB}"

# Install VirtualBox host packages
INSTALL_VIRTUALBOX="${INSTALL_VIRTUALBOX:-yes}"

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
  echo "This script requires the installer to be booted in UEFI mode."
  exit 1
fi

echo "About to ERASE and install Arch Linux on: $DISK"
sleep 5

# =========================
# Prep
# =========================
timedatectl set-ntp true
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

# =========================
# Partitioning
# Layout:
#   1 = EFI
#   2 = root
# =========================
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
partprobe "$DISK" || true
udevadm settle

sgdisk -o "$DISK"
sgdisk -n 1:1MiB:+"$EFI_SIZE" -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -N 2 -t 2:8300 -c 2:"root" "$DISK"

partprobe "$DISK" || true
udevadm settle
sleep 2

if [[ "$DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi

if [[ ! -b "$EFI_PART" || ! -b "$ROOT_PART" ]]; then
  echo "Partition devices not found after partitioning."
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
# Package lists
# =========================
BASE_PACKAGES=(
  base
  base-devel
  linux
  linux-headers
  linux-firmware
  grub
  efibootmgr
  networkmanager
  sudo
  nano
  vim
  git
  curl
  wget
  man-db
  man-pages
  texinfo
  dosfstools
  mtools
  bash-completion
  xdg-user-dirs
  xdg-utils
  pipewire
  pipewire-alsa
  pipewire-audio
  pipewire-jack
  pipewire-pulse
  wireplumber
  alsa-utils
  sof-firmware
  rtkit
  zram-generator
  sddm
  xorg
  xorg-server
  xorg-xinit
)

KDE_PACKAGES=(
  plasma-meta
  plasma-x11-session
  dolphin
  kate
  kdegraphics-thumbnailers
  ffmpegthumbs
)

EXTRA_PACKAGES=()

if [[ "$INSTALL_VIRTUALBOX" == "yes" ]]; then
  EXTRA_PACKAGES+=(
    virtualbox
    virtualbox-host-modules-arch
  )
fi

# =========================
# Install base system
# =========================
pacstrap -K /mnt \
  "${BASE_PACKAGES[@]}" \
  "${KDE_PACKAGES[@]}" \
  "${EXTRA_PACKAGES[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

# =========================
# System configuration
# =========================
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

sed -i 's/^#\\s*en_IE.UTF-8 UTF-8/en_IE.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

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

cat > /etc/vconsole.conf <<VCONSOLE
KEYMAP=ie
VCONSOLE

echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1 localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<ZRAMCONF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMCONF

echo "root:${ROOT_PASSWORD}" | chpasswd

useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

if [[ "${INSTALL_VIRTUALBOX}" == "yes" ]]; then
  usermod -aG vboxusers "${USERNAME}"
fi

sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

localectl set-locale LANG=en_IE.UTF-8 || true
localectl set-keymap ie || true

systemctl enable NetworkManager
systemctl enable sddm

mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg
EOF

# =========================
# Install paru
# =========================
arch-chroot /mnt /bin/bash -c "su - ${USERNAME} -c '
set -e
cd ~
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
'"

# =========================
# Install AUR packages
# =========================
arch-chroot /mnt /bin/bash -c "su - ${USERNAME} -c '
set -e
paru -S --noconfirm google-chrome visual-studio-code-bin
'"

echo
echo "Install complete."
echo
echo "Next steps:"
echo "  umount -R /mnt"
echo "  reboot"
