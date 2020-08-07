# debootscript
This is a bash script that [debootstraps](https://wiki.debian.org/Debootstrap) a minimal (--variant=minbase) bootable Debian or Ubuntu system with networking.

What it does:
* Sets up the partition table on a block device (GPT or MBR)
* Can set up LVM
* Formats the partitions (ext4 and fat32 - in case of GPT)
* Installs/configures bootloader (in case of MBR)
* Configures network (DHCP assumed on all interfaces)
* Sets up a username with sudo access to root
* Can install ssh for remote access

Requirements:
* Is run as root
* Linux system with bash
* curl if installing Ubuntu (can be avoided by specifying a mirror to use)
* mkfs.ext4 (mkfs.fat too if using GPT)
* debootstrap (non Debian-based systems might work with something like `cd / ; curl -O http://archive.ubuntu.com/ubuntu/pool/main/d/debootstrap/debootstrap_1.0.123ubuntu1_all.deb ; ar -x debootstrap_1.0.123ubuntu1_all.deb ; tar zxf data.tar.gz`)
* ip command (from iproute2)
* sfdisk
* 1GB of diskspace
