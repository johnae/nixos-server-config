#!/bin/sh

PREFIX=$1
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SUDO=
if [ "$(id -u)" != "0" ]; then
	SUDO=sudo
fi

FILES="configuration.nix"

OIFS=$IFS
IFS=" "

for FILE in $FILES; do
    if [ -f $FILE ]; then
        echo "Copying file $FILE to $PREFIX/etc/nixos/$FILE"
        $SUDO cp $FILE $PREFIX/etc/nixos/$FILE
    else
        echo "Not copying $FILE as it doesn't exist or is not a regular file"
    fi
done

IFS=$OIFS

if [ -z "$PREFIX" ]; then
    $SUDO nixos-rebuild switch
fi
