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

```
  Usage: ./debootscript.sh <options>
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
```
