#!/usr/bin/env bash

export SERVERNUM=$(hostname | tr -dc '[:digit:]')

lsblk -s | grep 'mpath $'| grep '^mpath' | sort | uniq >/tmp/1scan.$$

# Add mpath LUN to host after creation
for i in /sys/class/fc_host/host* ; do
        echo "1" > $i/issue_lip
done

sleep 5

lsblk -s | grep 'mpath $'| grep '^mpath' | sort | uniq >/tmp/2scan.$$

export WWN=$(cat /tmp/1scan.$$ /tmp/2scan.$$ | sort | uniq -u )
export DEVS=$(multipath -l $WWN | grep running | sed 's/^.*- //' | awk '{ print $2;}')

echo $WWN
echo
echo $DEvS

