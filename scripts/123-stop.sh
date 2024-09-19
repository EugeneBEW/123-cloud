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

i=0
e=0
running_vm=$(virsh $CONNECTSTRING list | grep "vm-${vm_id}[[:space:]]" | grep -v clone | cut -d' ' -f2 )
for id in $running_vm ; do
 echo "try to shutdown $vm_name (ID=$id target=$vm_target) grasefully"
 virsh $CONNECTSTRING shutdown $id
 until (( i >= 30 || e == 1 )) ; do
    virsh $CONNECTSTRING list | grep "vm-${vm_id}[[:space:]]" || \
    { echo "VM: vm-$vm_id (ID=$id target-$vm_targeti gracefully stopped"; exit 0; }
    if (( i <= 30 )) ; then
      sleep 1 && let ++i && echo $i
    else
      virsh $CONNECTSTRING destroy $id
      e=1 && die "Can\'t gracefully shutdown: call destroy vm!" 
    fi
  done  
done

stopped_vm=$(virsh $CONNECTSTRING list --all | grep "vm-${vm_id}[[:space:]]" | grep -v clone | awk  '{ print $2;}'  )
for i in $stopped_vm ; do
	echo "Can't stop stopped: $vm_name (ID=$i on target=$vm_target)"
	exit 0
done

