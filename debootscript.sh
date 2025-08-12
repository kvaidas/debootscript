#!/bin/bash
set -e
set -x
shopt -s nullglob
shopt -s extglob
kernel_parameters='rd.shell rd.auto console=ttyS0 console=tty0'

###########################
# Print usage information #
###########################

print_usage() {
  cat <<EOF
  Usage: $0 <options>
  Available options:
  -h                    print usage information
  -b <root_device>      (mandatory) which block device to install to
  -n <target_hostname>  hostname of target system (inherits current one if not specified)
  -t <partition_type>   partition type to use ("gpt" or "mbr")
  -e <password>         encrypt root partition with this password
  -l                    use LVM
  -d <distribution>     distribution to install ("debian" or "ubuntu")
  -r <release>          distro release to install
  -m <url>              mirror url to use
  -u <username>         (mandatory) name of user to create
  -s <ssh_key>          (mandatory if -p not used) install sshd and set this key for the new user
  -p <password>         (mandatory if -s not used) password to set for the new user
EOF
}

if [[ $# = 0 ]]; then
  print_usage
  exit 1
fi

while getopts hb:n:t:e:ld:r:m:u:s:p: options; do
  case $options in
    h)
      print_usage
      exit
      ;;
    b)
      root_device=$OPTARG
      ;;
    n)
      target_hostname=$OPTARG
      ;;
    t)
      partition_type=$OPTARG
      ;;
    e)
      encryption_password=$OPTARG
      ;;
    l)
      use_lvm=y
      ;;
    d)
      distro=$OPTARG
      ;;
    r)
      distro_release=$OPTARG
      ;;
    m)
      mirror=$OPTARG
      ;;
    u)
      target_user=$OPTARG
      ;;
    s)
      ssh_public_key=$OPTARG
      ;;
    p)
      target_password=$OPTARG
      ;;
    *)
      echo "Unknown option: $options"
      exit 1
    esac
done

########################
# Checks if we can run #
########################

if [[ $UID != 0 ]]; then
  echo 'You must be root to run this'
  exit 1
fi

# Check if required filesystems are supported
for fs in ext4 vfat; do
  if ! grep -q $fs /proc/filesystems; then
    echo "Filesystem $fs not supported by kernel"
    exit 1
  fi
done

for command in sfdisk mkfs.ext4 debootstrap ip; do
  if ! command -v $command &> /dev/null; then
    echo "Required command \"${command}\" not found"
    exit 1
  fi
done

if [ -z "$(blkid --version)" ]; then
  echo "Busybox blkid is incompatible with this script, use blkid from util-linux"
fi

# Check necessary parameters
if [[ -z $root_device ]]; then
  echo 'Root device not set' >&2
  exit 1
fi
if [[ ! -b $root_device ]]; then
  echo "Root block device ${root_device} not found" >&2
  exit 1
fi

if [[ -z $partition_type ]]; then
  if [ -e /sys/firmware/efi ]; then
    partition_type=gpt
  else
    partition_type=mbr
  fi
fi

if [[ -v encryption_password ]] && ! command -v cryptsetup &> /dev/null; then
  echo 'Required command "cryptsetup" not found' >&2
  exit 1
fi

if [[ $partition_type = gpt ]] && ! command -v mkfs.fat &> /dev/null; then
  echo 'Required command "mkfs.fat" not found' >&2
  exit 1
fi

if [[ -v use_lvm ]] && ! command -v pvcreate &> /dev/null; then
  echo 'Required command "pvcreate" not found, check if LVM utils are installed' >&2
  exit 1
fi

if [[ ! -v distro ]]; then
  echo 'Distro not specified'
  exit 1
fi
if [[ $distro != debian && $distro != ubuntu ]]; then
  echo "Only 'debian' and 'ubuntu' ar valid distros. You set it to: ${distro}"
  exit 1
fi

if [[ ! -v distro_release ]]; then
  echo 'Distro release not specified'
  exit 1
fi

if [[ ! -v mirror ]]; then
  if [[ $distro = ubuntu ]]; then
    mirror='http://archive.ubuntu.com/ubuntu/'
  else
    mirror='http://deb.debian.org/debian/'
  fi
fi


if [[ ! -v target_user ]]; then
  echo 'User name to create not specified' >&2
  exit 1
fi

if [[ ! -v ssh_public_key && ! -v target_password ]]; then
  echo 'Neither ssh key nor user password set - system will be inaccessible' >&2
  exit 1
fi

###########
# Install #
###########

# Create partitions
sfdisk --dump "${root_device}" || true

if [[ $partition_type = gpt ]]; then
  boot_partition_size=${boot_partition_size:=100}
  if [[ -v use_lvm ]] && [[ ! -v encryption_password ]]; then
    root_partition_type="E6D6D379-F507-44C2-A23C-238F2A3DF928"
  else
    root_partition_type="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"
  fi
  partition_script="
    size=${boot_partition_size}MiB type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
    type=${root_partition_type}
    "
  echo "$partition_script" | sfdisk --label gpt "${root_device}"
elif [[ $partition_type = mbr ]]; then
  boot_partition_size=${boot_partition_size:=200}
  if [[ -v use_lvm ]] && [[ ! -v encryption_password ]]; then
    root_partition_type="8e"
  else
    root_partition_type="83"
  fi
  partition_script="
    size=${boot_partition_size}MiB
    type=${root_partition_type}
  "
  echo "$partition_script" | sfdisk --label dos "${root_device}"
fi

# Encryption
if [[ -v encryption_password ]]; then
  echo -n "$encryption_password" \
  | cryptsetup luksFormat \
    --key-file - \
    --iter-time 10000 \
    --type luks2 \
    "$root_device"2
  echo -n "$encryption_password" | cryptsetup luksOpen --key-file=- "${root_device}2" encrypted
fi

# LVM
if [[ -v use_lvm ]]; then
  if [[ -v encryption_password ]]; then
    pvcreate /dev/mapper/encrypted
    vgcreate root_vg /dev/mapper/encrypted
  else
    pvcreate "${root_device}"2
    vgcreate root_vg "${root_device}"2
  fi
  lvcreate -y -l 100%FREE -n root_lv root_vg
fi

# Create filesystems
if [[ $partition_type = gpt ]]; then
  mkfs.fat -F32 "$root_device"1
else
  mkfs.ext2 -m 1 "$root_device"1
fi

if [[ -v use_lvm ]]; then
  mkfs.ext4 -m 1 /dev/mapper/root_vg-root_lv
elif [[ -v encryption_password ]]; then
  mkfs.ext4 -m 1 /dev/mapper/encrypted
else
  mkfs.ext4 -m 1 "$root_device"2
fi

# Mount filesystems
mkdir -p /target
if [[ -v use_lvm ]]; then
  mount /dev/mapper/root_vg-root_lv /target
elif [[ -v encryption_password ]]; then
  mount /dev/mapper/encrypted /target
else
  mount "${root_device}"2 /target
fi

if [[ $partition_type = gpt ]]; then
  mkdir -p /target/boot/efi
  mount -o umask=077 "${root_device}"1 /target/boot/efi
  uuid=$(blkid -o export "$root_device"2 | grep -E '^UUID=')
  echo "fs0:\vmlinuz root=${uuid} initrd=initrd.img" > /target/boot/efi/startup.nsh
else
  mkdir /target/boot
  mount "${root_device}"1 /target/boot
fi

# Debootstrap and chroot preparations
debootstrap --variant=minbase "$distro_release" /target "$mirror"

if [[ $partition_type = gpt ]]; then
  mkdir -p /target/etc/kernel/install.d
  printf '%s\n' \
    '#!/bin/bash' \
    'if [ $1 != "add" ]; then exit; fi' \
    'loader_config=/boot/efi/loader/entries/$(cat /etc/machine-id)-${2}.conf' \
    "sed -i'' '/^options / s#quiet#${kernel_parameters}#' \$loader_config" \
    > /target/etc/kernel/install.d/90-root-luks.install
  chmod +x /target/etc/kernel/install.d/90-root-luks.install
fi

# Create fstab (and crypttab if needed)
if [[ -v use_lvm ]]; then
  fstab_root='/dev/mapper/root_vg-root_lv'
elif [[ -v encryption_password ]]; then
  fstab_root='/dev/mapper/encrypted'
else
  fstab_root=$(blkid -o export "$root_device"2 | grep -E '^UUID=')
fi

if [[ -v encryption_password ]]; then
  uuid=$(blkid -o export "${root_device}2" | grep -E '^UUID=')
  echo "encrypted $uuid none luks" > /target/etc/crypttab
  printf '%s\n' \
    "sed -i'' '/^options / s#\$# cryptdevice=${uuid}:encrypted root=${fstab_root}#' \$loader_config" \
    >> /target/etc/kernel/install.d/90-root-luks.install
fi

echo "$fstab_root / ext4 rw,noatime,nodiratime 0 1" > /target/etc/fstab

echo -e "APT::Install-Recommends no;\nAPT::Install-Suggests no;" > /target/etc/apt/apt.conf.d/90no-extra
mount --bind /dev /target/dev

####################
# Chrooted actions #
####################

chroot_actions() {
  mount -t sysfs sys /sys
  mount -t proc proc /proc
  if [[ $partition_type = gpt ]]; then
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars
  fi

  if [[ -n $target_hostname ]]; then
    hostname "$target_hostname" && echo "$target_hostname" > /etc/hostname
  fi
  apt-get update

  # Packages that depend on storage setup
  if [[ -v use_lvm ]]; then
    apt-get install -y lvm2
  fi
  if [[ -v encryption_password ]]; then
    apt-get install -y systemd-cryptsetup cryptsetup
  fi
  if [[ $partition_type = gpt ]]; then
    apt-get install -y systemd-boot
  else
    echo "grub-pc grub-pc/install_devices multiselect ${root_device}" | debconf-set-selections
    apt-get install -y grub-pc
    sed -i'' "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"${kernel_parameters}\"/" /etc/default/grub
    update-grub
    grub-install "${root_device}"
  fi

  # Common packages
  apt-get install -y netbase systemd-sysv whiptail sudo dracut e2fsprogs

  # Distro-specific packages
  if [[ $distro = ubuntu ]]; then
    apt-get install -y linux-image-generic
  else
    apt-get install -y "linux-image-$(dpkg --print-architecture)"
  fi

  # Set up access
  useradd -m -s /bin/bash -G sudo "${target_user}"
  if [[ -v target_password ]]; then
    echo -e "${target_password}\n${target_password}" | passwd "$target_user"
  fi
  if [[ -v ssh_public_key ]]; then
    apt-get install -y ssh
    local homedir
    homedir=$(eval echo ~"${target_user}")
    mkdir -m 700 "${homedir}/.ssh"
    echo "${ssh_public_key}" > "${homedir}/.ssh/authorized_keys"
    chmod 600 "${homedir}/.ssh/authorized_keys"
    chown -R "${target_user}:${target_user}" "${homedir}"
  fi

  # Set up network
  systemctl enable systemd-networkd
  printf '%s\n' \
    '[Match]' \
    'Type=ether' \
    '[Network]' \
    'DHCP=yes' \
  > /etc/systemd/network/20-dhcp.network

  # Finish up
  apt-get clean
}
export root_device target_hostname use_lvm partition_type encryption_password distro target_user target_password ssh_public_key kernel_parameters
chroot /target /bin/bash -O nullglob -O extglob -ec "$(declare -f chroot_actions) && chroot_actions"

###########
# Cleanup #
###########

if [[ $partition_type = gpt ]]; then
  umount /target/sys/firmware/efi/efivars /target/boot/efi
else
  umount /target/boot
fi
for fs in proc dev sys ''; do umount "/target/$fs"; done
if [[ -v use_lvm ]]; then
  vgchange -an root_vg
fi
if [[ -v encryption_password ]]; then
  cryptsetup close encrypted
fi
