#!/usr/bin/env bash
set -euo pipefail

# =========================
# User-configurable values
# =========================
DISK="${DISK:-/dev/sda}"
HOSTNAME="${HOSTNAME:-arch}"
USERNAME="${USERNAME:-user}"
USER_PASSWORD="${USER_PASSWORD:-changeme}"
ROOT_PASSWORD="${ROOT_PASSWORD:-rootchangeme}"
TIMEZONE="${TIMEZONE:-Europe/Dublin}"
EFI_SIZE_MIB="${EFI_SIZE_MIB:-1024}"

# =========================
# Safety checks
# =========================
if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root from the Arch ISO."
  exit 1
fi

if [[ ! -b "$DISK" ]]; then
  echo "Disk $DISK does not exist."
  exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
  echo "This script assumes a UEFI booted installer."
  exit 1
fi

echo "About to WIPE and install Arch Linux on: $DISK"
sleep 3

# =========================
# Time sync
# =========================
timedatectl set-ntp true

# =========================
# Partitioning
# Layout:
# 1: EFI
# 2: root
# =========================
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"

partprobe "$DISK" || true

sgdisk -n 1:1MiB:"${EFI_SIZE_MIB}MiB" -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:"${EFI_SIZE_MIB}MiB":0 -t 2:8300 -c 2:"root" "$DISK"

partprobe "$DISK"
udevadm settle

# Handle nvme/mmcblk naming
if [[ "$DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
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
# Base install
# =========================
pacstrap -K /mnt \
  base \
  base-devel \
  linux \
  linux-headers \
  linux-firmware \
  networkmanager \
  grub \
  efibootmgr \
  sudo \
  nano \
  vim \
  git \
  wget \
  curl \
  man-db \
  man-pages \
  texinfo \
  reflector \
  os-prober \
  dosfstools \
  mtools \
  xdg-user-dirs \
  xdg-utils \
  bash-completion \
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
  xorg-xinit \
  xorg-server \
  virtualbox \
  virtualbox-host-modules-arch \
  virtualbox-guest-iso

genfstab -U /mnt >> /mnt/etc/fstab

# =========================
# Chroot configuration
# =========================
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Timezone and clock
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

# Locale generation
sed -i 's/^#\\s*en_IE.UTF-8 UTF-8/en_IE.UTF-8 UTF-8/' /etc/locale.gen
locale-gen

# NixOS-like locale settings
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

# zram swap
cat > /etc/systemd/zram-generator.conf <<ZRAMCONF
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMCONF

# Hostname
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# Root password
echo "root:${ROOT_PASSWORD}" | chpasswd

# User creation
useradd -m -G wheel,vboxusers -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

# Sudo for wheel
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Keyboard
localectl set-keymap ie || true

# Services
systemctl enable NetworkManager
systemctl enable sddm

# Initramfs
mkinitcpio -P

# Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
grub-mkconfig -o /boot/grub/grub.cfg

# Build paru as normal user
sudo -u "${USERNAME}" bash <<PARUUSER
set -euo pipefail
cd /home/${USERNAME}
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
PARUUSER

# Install Google Chrome from AUR
sudo -u "${USERNAME}" bash <<CHROMEUSER
set -euo pipefail
paru -S --noconfirm google-chrome
CHROMEUSER
EOF

echo
echo "Install complete."
echo "Now run:"
echo "  umount -R /mnt"
echo "  reboot"