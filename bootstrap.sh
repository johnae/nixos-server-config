#!/bin/sh

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

## This script bootstraps a nixos install. The assumptions are:
# 1. You want an EFI System Partition (500MB) - so no BIOS support
# 2. You want swap space size to be half of RAM as per modern standards (eg. see https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/7/html/installation_guide/sect-disk-partitioning-setup-x86#sect-recommended-partitioning-scheme-x86)
# 3. You want to use btrfs for everything else
# 4. You want to not care about atime and you want to compress your fs using zstd

# set -x

## Generally this should really be /dev/random as that will be cryptographically of high quality,
## however for testing purposes I allow it to be overridden. Just don't do this unless you have a
## good reason. For example, in a VM when testing the install script, it may be beneficial to use urandom
## instead as it will likely generate entropy properly as opposed to random.

DEVRANDOM=${DEVRANDOM:-/dev/random}
EXTERNALDISK=${EXTERNALDISK:-}

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

if [ -n "$EXTERNALDISK" ]; then
    if [ ! -e "$EXTERNALDISK" ]; then
        echo "'$EXTERNALDISK' does not exist but was given"
        exit 1
    fi
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

PARTITION_PREFIX=""
if echo "$DISK" | grep -q "nvme"; then
    PARTITION_PREFIX="p"
fi

ENIF=${1:-"eth0"}
shift
if [ -z "$ENIF" ]; then
    echo "You must provide the (ethernet) network interface name as the fourth argument"
    exit 1
fi

GATEWAY=$(echo $IPV4 | sed -E 's|[0-9]+$|1|g')
HOSTID=$(head -c4 /dev/urandom | od -A none -t x4 | sed 's| ||g')
#ETHMOD=$(lspci -v -s $(lspci | grep Ethernet | awk '{print $1}') | grep "Kernel modules" | awk '{print $NF}')

echo "---------------------------- Review ---------------------------"
echo "Disk: $DISK"
echo "Hostname: $HNAME"
echo "Ip: $IPV4"
echo "Ethernet interface: $ENIF"
echo "HostId: $HOSTID"
#echo "Ethernet module: '$ETHMOD'"
echo "---------------------------------------------------------------"

echo "Will completely erase and format '$DISK', proceed? (y/n)"
read answer
if ! echo "$answer" | grep '^[Yy].*' 2>&1>/dev/null; then
    echo "Ok bye."
    exit
fi

# clear out the disk completely
wipefs -fa $DISK
sgdisk -Z $DISK

# clear out any efi dumps
rm -f /sys/firmware/efi/efivars/dump-*

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
#sgdisk -n 0:0:+$luks_key_space -t 0:8300 -c 0:"cryptkey" $DISK # 2
sgdisk -n 0:0:+$swap_space -t 0:8300 -c 0:"swap" $DISK # 2
sgdisk -n 0:0:0 -t 0:8300 -c 0:"root" $DISK # 3

DISK_EFI=$DISK$PARTITION_PREFIX"1"
#DISK_CRYPTKEY=$DISK$PARTITION_PREFIX"2"
DISK_SWAP=$DISK$PARTITION_PREFIX"2"
DISK_ROOT=$DISK$PARTITION_PREFIX"3"
#ZROOT=zroot

sgdisk -p $DISK

# make sure everything knows about the new partition table
partprobe $DISK
fdisk -l $DISK

mkswap -f $DISK_SWAP
swapon $DISK_SWAP

mkfs.btrfs -f -L root $DISK_ROOT
mount -o rw,noatime,compress=zstd,ssd,space_cache \
      $DISK_ROOT /mnt

# create the efi boot partition
mkfs.vfat $DISK_EFI

cd /mnt
btrfs subvolume create @ ## root
mkdir -p "@/boot" "@/home" "@/var" "@/mnt"
btrfs subvolume create @home
btrfs subvolume create @var

if [ -n "$EXTERNALDISK" ]; then

    echo "Will completely erase and format '$EXTERNALDISK', proceed? (y/n)"
    read answer
    if ! echo "$answer" | grep '^[Yy].*' 2>&1>/dev/null; then
        echo "Ok bye."
        exit
    fi

    wipefs -fa $EXTERNALDISK
    sgdisk -Z $EXTERNALDISK
    mkdir -p "@/mnt/volumes" "@/mnt/volumes-nocow"
    mkfs.btrfs -f -L external $EXTERNALDISK
    ## temp mount
    mount -o rw,noatime,compress=zstd,ssd,space_cache \
          $EXTERNALDISK /mnt/@/mnt/volumes

    cd @/mnt/volumes
    for N in $(seq 1 20); do
        btrfs subvolume create "@local-volume-$N"
        btrfs subvolume create "@local-volume-nocow-$N"
        chattr -R +C "@local-volume-nocow-$N"
    done
    cd /mnt
    umount /mnt/@/mnt/volumes
fi

cd $DIR
umount /mnt

# mount the "root" (@) subvolume to /mnt
mount -o rw,noatime,compress=zstd,ssd,space_cache,subvol=@ \
      $DISK_ROOT /mnt
# mount @home subvolume to /mnt/home
mount -o rw,noatime,compress=zstd,ssd,space_cache,subvol=@home \
      $DISK_ROOT /mnt/home
# mount @var subvolume to /mnt/var
mount -o rw,noatime,compress=zstd,ssd,space_cache,subvol=@var \
      $DISK_ROOT /mnt/var

BOOT_UUID=$(ls -lah /dev/disk/by-uuid/ | \
                grep $(basename $DISK_EFI) | awk '{print $9}')
# and mount the boot partition
mount /dev/disk/by-uuid/$BOOT_UUID /mnt/boot

# finally, if applicable, mount external disks
if [ -n "$EXTERNALDISK" ]; then
    echo "Mounting disks from $EXTERNALDISK"
    for N in $(seq 1 20); do
        mkdir -p "/mnt/mnt/volumes/local-volume-$N"
        mount -o rw,noatime,compress=zstd,ssd,space_cache,subvol="@local-volume-$N" \
              $EXTERNALDISK "/mnt/mnt/volumes/local-volume-$N"
        mkdir -p "/mnt/mnt/volumes-nocow/local-volume-$N"
        mount -o rw,noatime,compress=zstd,ssd,space_cache,subvol="@local-volume-nocow-$N" \
              $EXTERNALDISK "/mnt/mnt/volumes-nocow/local-volume-$N"
        chattr -R +C "/mnt/mnt/volumes-nocow/local-volume-$N"
    done
fi

echo "Now please make any customizations before we generate the config... (type 'exit' + enter when done)"
sh
echo "continuing..."

nixos-generate-config --root /mnt
cp configuration.nix /mnt/etc/nixos/configuration.nix
cp meta-template.nix /mnt/etc/nixos/meta.nix

sed -i"" "s|<HOSTNAME>|$HNAME|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<HOSTID>|$HOSTID|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<IPV4>|$IPV4|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<GATEWAY>|$GATEWAY|g" /mnt/etc/nixos/meta.nix
sed -i"" "s|<ENIF>|$ENIF|g" /mnt/etc/nixos/meta.nix
sed -i"" 's|\("subvol=@.*"\)|\1 "rw" "noatime" "compress=zstd" "space_cache"|g' /mnt/etc/nixos/hardware-configuration.nix
#sed -i"" "s|<ETHMOD>|$ETHMOD|g" /mnt/etc/nixos/meta.nix

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
#nix-shell -p dropbear --command "dropbearkey -t ecdsa -f /mnt/etc/nixos/initrd-ssh-key"

echo "Now modify anything else you need in /mnt/etc/nixos/meta.nix"
echo "then run 'nixos-install'"