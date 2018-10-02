#!/bin/sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

## This script bootstraps a nixos install. The assumptions are:
# 1. You want an EFI System Partition (500MB) - so no BIOS support
# 2. You want encrypted root and swap
# 3. You want swap space size to be half of RAM as per modern standards (eg. see https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/installation_guide/sect-disk-partitioning-setup-x86#sect-recommended-partitioning-scheme-x86)
# 4. You want to use zfs for everything else
# 5. You want to not care about atime and you want to compress your fs

# set -x

## Generally this should really be /dev/random as that will be cryptographically of high quality,
## however for testing purposes I allow it to be overridden. Just don't do this unless you have a
## good reason. For example, in a VM when testing the install script, it may be beneficial to use urandom
## instead as it will likely generate entropy properly as opposed to random.

if ! cat /etc/nixos/configuration.nix | grep -q zfs 2>&1 >/dev/null; then
    sed -i"" 's|}$|  boot.zfs.enableUnstable = true;\n  boot.supportedFilesystems = [ "zfs" ];\n}|g' /etc/nixos/configuration.nix
    nixos-rebuild switch
fi
cat /etc/nixos/configuration.nix

DEVRANDOM=${DEVRANDOM:-/dev/random}

## This will be formatted! It should be the path to the device, not a partition.
DISK=$1
shift
if [ -z "$DISK" ]; then
    echo "You must set the DISK env var (this WILL be formatted so be careful!)"
    exit 1
fi

if [ ! -e "$DISK" ]; then
    echo "'$DISK' does not exist"
    exit 1
fi

HNAME=$1 ## hostname
shift
if [ -z "$HNAME" ]; then
    echo "You must provide a hostname as the second argument"
    exit 1
fi

IPV4=$1
shift
if [ -z "$IPV4" ]; then
    echo "You must provide an ipv4 address as the third argument"
    exit 1
fi

ENIF=${1:-"eth0"}
shift
if [ -z "$ENIF" ]; then
    echo "You must provide the (ethernet) network interface name as the fourth argument"
    exit 1
fi

GATEWAY=$(echo $IPV4 | sed -E 's|[0-9]+$|1|g')
HOSTID=$(head -c4 /dev/urandom | od -A none -t x4 | sed 's| ||g')
echo "-------------------------------------------------------------"
echo "Disk: $DISK"
echo "Hostname: $HNAME"
echo "Ip: $IPV4"
echo "Ethernet interface: $ENIF"
echo "HostId: $HOSTID"
ETHMOD=$(lspci -v -s $(lspci | grep Ethernet | awk '{print $1}') | grep "Kernel modules" | awk '{print $NF}')
echo "Ethernet module: '$ETHMOD'"
echo "-------------------------------------------------------------"

if ! echo "$DISK" | grep -q "by-id"; then
    echo "Please reference the disk via /dev/by-id path"
    exit 1
fi

echo "Will completely erase and format '$DISK', proceed? (y/n)"
read answer
if ! echo "$answer" | grep '^[Yy].*' 2>&1>/dev/null; then
    echo "Ok bye."
    exit
fi

# clear out the disk completely
wipefs -fa $DISK
sgdisk -Z $DISK

efi_space=500M # EF00 EFI Partition
#luks_key_space=3M # 8300
# set to half amount of RAM
swap_space=$(($(free --giga | tail -n+2 | head -1 | awk '{print $2}') / 2))G # 8300
# special case when there's very little ram - perhaps this should be dealt with differently?
if [ "$swap_space" = "0G" ]; then
    swap_space="1G"
fi
# rest (eg. root) will use the remaining space (btrfs) 8300

# now ensure there's a fresh GPT on there
sgdisk -og $DISK

sgdisk -n 0:0:+$efi_space -t 0:ef00 -c 0:"efi" $DISK # 1
# sgdisk -n 0:0:+$luks_key_space -t 0:8300 -c 0:"cryptkey" $DISK # 2
#sgdisk -n 0:0:+$swap_space -t 0:8300 -c 0:"swap" $DISK # 3
sgdisk -n 0:0:0 -t 0:BF01 -c 0:"zfsroot" $DISK # 2

DISK_EFI=$DISK$PARTITION_PREFIX"-part1"
#DISK_CRYPTKEY=$DISK$PARTITION_PREFIX"2"
#DISK_SWAP=$DISK$PARTITION_PREFIX"3"
DISK_ROOT=$DISK$PARTITION_PREFIX"-part2"
ZROOT=zroot

sgdisk -p $DISK

# make sure everything knows about the new partition table
partprobe $DISK
fdisk -l $DISK

#nix-env -iA nixos.zfsUnstable

# create the encrypted zpool
zpool create -f -o ashift=12 -o altroot="/mnt" -O compression=lz4 -O encryption=aes-256-gcm -O keyformat=passphrase $ZROOT $DISK_ROOT

zfs create -V $swap_space -b $(getconf PAGESIZE) -o compression=zle \
    -o logbias=throughput -o sync=always \
    -o primarycache=metadata -o secondarycache=none \
    -o com.sun:auto-snapshot=false $ZROOT/swap

zfs create -o mountpoint=none $ZROOT/root
zfs create -o mountpoint=legacy $ZROOT/root/nixos
zfs create -o mountpoint=legacy $ZROOT/home

mkswap -f /dev/zvol/$ZROOT/swap
swapon /dev/zvol/$ZROOT/swap

mount -t zfs $ZROOT/root/nixos /mnt

mkdir -p /mnt/home
mount -t zfs $ZROOT/home /mnt/home

# create the efi boot partition
mkfs.vfat $DISK_EFI
mkdir -p /mnt/boot
mount $DISK_EFI /mnt/boot

nixos-generate-config --root /mnt
cp configuration.nix /mnt/etc/nixos/configuration.nix
cp meta-template.nix /mnt/etc/nixos/meta.nix

sed -i"" "s|<HOSTNAME>|$HNAME|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<HOSTID>|$HOSTID|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<IPV4>|$IPV4|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<GATEWAY>|$GATEWAY|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<ENIF>|$ENIF|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<ETHMOD>|$ETHMOD|g" /mnt/etc/nixos/meta.nix

echo "-- setting user login password --"
## NOTE: -s -p aren't posix compatible but they will work just fine for this
while [ -z "$USERPASS" ]; do
    echo "Please type your password."
    read -s -p "password: " USERPASS
    echo "Please retype your password."
    read -s -p "password again: " USERPASS2
    if [ "$USERPASS" != "$USERPASS2" ]; then
        echo "Different passwords given, again please."
        unset USERPASS
    fi
    unset USERPASS2
done

PASS=$(nix-shell -p mkpasswd --command "mkpasswd -m sha-512 -s <<< $USERPASS")
unset USERPASS

sed -i"" "s|<PASSWORD>|$PASS|g" /mnt/etc/nixos/meta.nix
unset PASS

## Generate the dropbear initrd ssh keys
nix-shell -p dropbear --command "dropbearkey -t ecdsa -f /mnt/etc/nixos/initrd-ssh-key"

echo "Now modify anything else you need in /mnt/etc/nixos/meta.nix"
echo "then run 'nixos-install'"