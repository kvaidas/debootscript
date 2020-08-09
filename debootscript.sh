#!/bin/bash
shopt -s nullglob
shopt -s extglob

###########################
# Print usage information #
###########################

print_usage() {
  cat <<EOF
  Usage: $0 <options>
  Available options:
  -h                    print usage information
  -b <root_device>      (mandatory) which block device to install to
  -n <target_hostname>  hostname of target system
  -t <partition_type>   partition type to use ("gpt" or "mbr")
  -l                    use LVM
  -d                    install debian instead of ubuntu
  -r <release>          distro release (defaults are focal for ubuntu and buster for debian)
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

while getopts hb:n:t:ldr:m:u:s:p: options; do
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
    l)
      use_lvm=y
      ;;
    d)
      distro=debian
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

for command in mkfs.ext4 debootstrap ip; do
  if ! command -v $command &> /dev/null; then
    echo "Required command \"${command}\" not found"
    exit 1
  fi
done

# Check necessary parameters

if [[ -z $root_device ]]; then
  echo 'Root device not set' >&2
  exit 1
fi
if [[ ! -b $root_device ]]; then
  echo "Root block device ${root_device} not found" >&2
  exit 1
fi

if [[ $partition_type != gpt && $partition_type != mbr ]]; then
  echo "Unsupported partition type: ${partition_type}" >&2
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
  distro=ubuntu
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
  if [[ -v use_lvm ]]; then
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
  if [[ -v use_lvm ]]; then
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

# LVM
if [[ -v use_lvm ]]; then
  pvcreate "${root_device}"2
  vgcreate root_vg "${root_device}"2
  lvcreate -y -L 1G -n root_lv root_vg
fi

# Create filesystems
if [[ $partition_type = gpt ]]; then
  mkfs.fat -F32 "$root_device"1
else
  mkfs.ext2 -m 1 "${root_device}"1
fi
if [[ -v use_lvm ]]; then
  mkfs.ext4 -m 1 /dev/mapper/root_vg-root_lv
  root_uuid=$(blkid -o export /dev/mapper/root_vg-root_lv | grep -E '^UUID=')
else
  mkfs.ext4 -m 1 "${root_device}"2
  root_uuid=$(blkid -o export "${root_device}"2 | grep -E '^UUID=')
fi

# Mount filesystems
mkdir /target
if [[ -v use_lvm ]]; then
  mount /dev/mapper/root_vg-root_lv /target
else
  mount "${root_device}"2 /target
fi
if [[ $partition_type = gpt ]]; then
  mkdir -p /target/boot/efi
  mount "${root_device}"1 /target/boot/efi
  echo "fs0:\vmlinuz root=${root_uuid} initrd=initrd.img" > /target/boot/efi/startup.nsh
else
  mkdir /target/boot
  mount "${root_device}"1 /target/boot
fi

# Debootstrap and chroot preparations
if [[ $distro = ubuntu ]]; then
  distro_release=${distro_release:="focal"}
  if [[ ! -v mirror ]]; then
    mirror=$(curl -s mirrors.ubuntu.com/mirrors.txt | head -1)
  fi
else
  distro_release=${distro_release:="buster"}
  if [[ -v mirror ]]; then
    mirror="http://ftp.debian.org/debian/"
  fi
fi
debootstrap --variant=minbase "$distro_release" /target "$mirror"
for fs in proc dev sys; do mount --bind /$fs /target/$fs; done
echo "$root_uuid / ext4 rw,noatime,nodiratime 0 1" > /target/etc/fstab
echo -e "APT::Install-Recommends no;\nAPT::Install-Suggests no;" > /target/etc/apt/apt.conf.d/90no-extra

####################
# Chrooted actions #
####################

chroot_actions() {
  if [[ -n $target_hostname ]]; then
    hostname "$target_hostname" && echo "$target_hostname" > /etc/hostname
  fi
  apt-get update

  # Packages that depend on storage setup
  if [[ -v use_lvm ]]; then
    apt-get install -y lvm2
  fi
  if [[ $partition_type = gpt ]]; then
    local kernel_path
    kernel_path='/'
    if [[ $distro = ubuntu ]]; then
      kernel_path="${kernel_path}boot"
    fi
    echo -e "#!/bin/sh\ncp -f ${kernel_path}/vmlinuz ${kernel_path}/initrd.img /boot/efi" > \
      /etc/kernel/postinst.d/zz-update-efistub
    chmod +x /etc/kernel/postinst.d/zz-update-efistub
  else
    echo "grub-pc grub-pc/install_devices multiselect ${root_device}" | debconf-set-selections
    apt-get install -y grub-pc
  fi

  # Common packages
  apt-get install -y netbase isc-dhcp-client systemd-sysv whiptail sudo initramfs-tools

  # Distro-specific packages
  if [[ $distro = ubuntu ]]; then
    apt-get install -y linux-image-virtual netplan.io
  else
    apt-get install -y "linux-image-$(dpkg --print-architecture)" ifupdown
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
  if [[ $distro = ubuntu ]]; then
    printf '%s\n' \
      'network:' \
      '  version: 2' \
      '  renderer: networkd' \
      '  ethernets:' \
      > /etc/netplan/interfaces.yaml
    for interface in /sys/class/net/!(lo); do
      interface=$(basename "$interface")
      printf '%s\n' \
        "    $interface:" \
        '      dhcp4: true' \
        >> /etc/netplan/interfaces.yaml
    done
  else
    for interface in /sys/class/net/!(lo); do
      interface=$(basename "$interface")
      echo "auto ${interface}" >> /etc/network/interfaces
      echo -e "iface ${interface} inet dhcp" >> /etc/network/interfaces
    done
  fi

  # Finish up
  apt-get autoremove
  apt-get clean
}
export root_device target_hostname use_lvm partition_type distro target_user target_password ssh_public_key
chroot /target /bin/bash -O nullglob -O extglob -ec "$(declare -f chroot_actions) && chroot_actions"

###########
# Cleanup #
###########

if [[ $partition_type = gpt ]]; then
  umount /target/boot/efi
else
  umount /target/boot
fi
for fs in proc dev sys ''; do umount "/target/$fs"; done
