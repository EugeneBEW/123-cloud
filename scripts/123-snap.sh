#!/bin/bash

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh

export LANG=C
prog=$(basename $0)

usage() { echo "Usage: $prog -i <vm_id> [ -n <vm_-name> ]" 1>&2; exit 1; }


#vm_id=$(check_configs_id id)
vm_name="vm-$vm_id"

vm_target=$(hostname | tr -cd '[:digit:]')

while getopts ":i::n::" o; do
  case "${o}" in
    n)
    vm_name=${OPTARG}
    check_configs 'networks.name' $vm_name
    ;;
    i)
    vm_id=${OPTARG}
    test_configs id $vm_id && die "VM with ID: $vm_id not exist"
    ;;
    *)
    usage
    ;;
  esac
done
shift $((OPTIND-1))


if [[ "X${vm_id}" == "X" ]]; then
    usage
fi

echo continue with $vm_id

file=$VMCONFIGDIR/vm-$vm_id-config.yml

[[ ! -f $file ]] && die "cant't find config file $file for vm-$vm_id"

vm_name=$(cat $file | $SCRIPTSDIR/yq r - name)
vm_target=$(cat $file | $SCRIPTSDIR/yq r - target)

# определеяем на каком гипервизоре стартовать ВМ
target_=${BECOME_USER}@${SERVER_PREFIX}${vm_target}
CONNECTSTRING="--connect qemu+ssh://$target_/system"

# ищем подходящий LVM вольюм на быстром разделе у нас они названы SSD или DATA1 - кто именно не важно
ssd_pool=$(virsh $CONNECTSTRING pool-list 2>/dev/null | egrep 'DATA1|SSD' | cut -d' ' -f2 | head -1 )
hdd_pool=$(virsh $CONNECTSTRING pool-list 2>/dev/null | egrep 'DATA2|HDD' | cut -d' ' -f2 | head -1 )
#
ssd_vols=$(virsh $CONNECTSTRING vol-list $ssd_pool | grep vm-${vm_id} | grep -v clone | cut -d' ' -f2 )
hdd_vols=$(virsh $CONNECTSTRING vol-list $hdd_pool | grep vm-${vm_id} | grep -v clone | cut -d' ' -f2 )

echo $ssd_vols  $hdd_vols
consistent_flag=""

virsh $CONNECTSTRING domstate vm-$vm_id | grep 'running' >/dev/null && {

  pid=$(virsh $CONNECTSTRING qemu-agent-command vm-$vm_id --cmd '{"execute": "guest-exec", "arguments": { "path": "/usr/bin/sync", "capture-output": true }}' \
  | jq '.return.pid')

#echo $pid
  i=0
  e=0
  outputn $(yellow "syncing runing guest. wait")
  consistent_flag=non
  [[ -n $pid ]] && until (( i >= 300 || e == 1 )) ; do 
    {
    if (( i <= 300 )) ; then
	    sleep 1 && let ++i && echo -n "."
    else
        echo; yellow "Cant' sync guests filesystem"
        e=1
    fi
  
    set $(virsh $CONNECTSTRING qemu-agent-command vm-$vm_id --cmd "{\"execute\": \"guest-exec-status\", \"arguments\": { \"pid\": $pid }}" \
      | jq '.return|.exited,.exitcode')
  
    [[ "$1" == 'true' && $2 == '0'  ]] && break;
    }
  done
  echo
}
suffix=$(date '+%Y%m%d-%H%M%S')
# TO DO [[ $consistent_flag == 'non' ]] do suspend if available in comand options 
for vol in $ssd_vols; do 
    ssh  $target_ sudo lvcreate --snapshot --size 10G --name pre-snap-$vol-$suffix $ssd_pool/$vol
done

for vol in $hdd_vols; do 
    ssh  $target_ sudo lvcreate --snapshot --size 10G --name pre-snap-$vol-$suffix $hdd_pool/$vol
done

for vol in $ssd_vols; do 
	vol_size=$(ssh $target_ sudo lvs -o size --units 'g' --reportformat json $ssd_pool/$vol | jq .report[0].lv[0].lv_size)
	echo "Make $consistent_flag consistent snapshot $vol_size $ssd_pool/$vol"
        echo $vol_size | egrep '[1-9]' >/dev/null && ssh  $target_ "sudo lvcreate -y --size $vol_size --name snap-$vol-$suffix $ssd_pool && \
	sudo dd status=progress bs=1024M if=/dev/$ssd_pool/pre-snap-$vol-$suffix of=/dev/$ssd_pool/snap-$vol-$suffix && \
        sudo lvremove -y $ssd_pool/pre-snap-$vol-$suffix" || die "Empty volume size for $ssd_pool/$vol !!!"
done

for vol in $hdd_vols; do 
	vol_size=$(ssh $target_ sudo lvs -o size --units 'g' --reportformat json $hdd_pool/$vol | jq .report[0].lv[0].lv_size)
	echo "Make $consistent_flag consistent snapshot $vol_size $hdd_pool/$vol"
        echo $vol_size | egrep '[1-9]' >/dev/null && ssh  $target_ "sudo lvcreate -y --size $vol_size --name snap-$vol-$suffix $hdd_pool && \
	sudo dd status=progress bs=1024M if=/dev/$hdd_pool/pre-snap-$vol-$suffix of=/dev/$hdd_pool/snap-$vol-$suffix && \
        sudo lvremove -y $hdd_pool/pre-snap-$vol-$suffix" || die "Empty volume size for $hdd_pool/$vol !!!"
done

