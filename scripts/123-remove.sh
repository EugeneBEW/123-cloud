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

# определеяем откуда удалять ВМ
target_=${BECOME_USER}@${SERVER_PREFIX}${vm_target}
CONNECTSTRING="--connect qemu+ssh://$target_/system"

# ищем подходящий LVM вольюм на быстром разделе у нас они названы SSD или DATA1 - кто именно не важно
ssd_pool=$(virsh $CONNECTSTRING pool-list 2>/dev/null | egrep 'DATA1|SSD' | cut -d' ' -f2 | head -1 )
hdd_pool=$(virsh $CONNECTSTRING pool-list 2>/dev/null | egrep 'DATA2|HDD' | cut -d' ' -f2 | head -1 )

ssd_vols=$(virsh $CONNECTSTRING vol-list $ssd_pool | grep vm-${vm_id} | grep -v clone | cut -d' ' -f2 )
hdd_vols=$(virsh $CONNECTSTRING vol-list $hdd_pool | grep vm-${vm_id} | grep -v clone | cut -d' ' -f2 )

#[[ -z "$ssd_vols" -a -z "$hdd_vols" ]] && die "can't find VM volumes for removing on $target"

removed_running_vm=$(virsh $CONNECTSTRING list | grep "vm-${vm_id}[[:space:]]" | grep -v clone | cut -d' ' -f2 )
for i in $removed_running_vm ; do
 echo "remove running: $i"
 virsh $CONNECTSTRING destroy $i
done

removed_stopped_vm=$(virsh $CONNECTSTRING list --all | grep "vm-${vm_id}[[:space:]]" | grep -v clone | awk  '{ print $2;}'  )
for i in $removed_stopped_vm ; do
  echo "remove stopped: $i"
  virsh $CONNECTSTRING undefine $i
done

for i in $ssd_vols ; do
  echo "remove ssd volume: $i"
  virsh $CONNECTSTRING vol-delete --pool $ssd_pool $i
done

for i in $hdd_vols ; do
  echo "remove hdd volume: $i"
  virsh $CONNECTSTRING vol-delete --pool $hdd_pool $i
done

for hid in $(eval echo "$(get_target_list)"); do
	echo $hid
        ssh $SSHOPTIONS ${BECOME_USER}@${SERVER_PREFIX}${hid} "sudo rm -f $CIDATADIR/vm-${vm_id}-cidata.iso"
done && echo "remove cidata from all nodes... pass"

# удаляем конфиг на все серверы группировки, кроме того где конфиг был создан
for hid in $(eval echo "$(get_target_list)"); do
	echo $hid
        ssh $SSHOPTIONS ${BECOME_USER}@${SERVER_PREFIX}${hid} "sudo rm -f $VMCONFIGDIR/vm-${vm_id}-config.yml"
done && echo 'remove config from all nodes'

