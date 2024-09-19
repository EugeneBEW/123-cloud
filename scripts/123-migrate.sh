#!/bin/bash

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

#[[ -f $SCRIPTSDIR/123-defs.sh ]] && source $SCRIPTSDIR/123-defs.sh
eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh


export LANG=C
prog=$(basename $0)

usage() { echo "Usage: $prog -i <vm_id> [ -t <target> ] [ -s ]
	move/live migrate VM to target hypervisor (or current hypervisor if ommited) 
	-s don't remove offline sources" 1>&2; exit 1; }

local_id=$(hostname | tr -cd '[:digit:]')
vm_target=$local_id

while getopts ":i::t::s" o; do
  case "${o}" in
    t)
    vm_target=${OPTARG}	
    check_target $vm_target || die "wrong target server number: $vm_target..."
    ;;
    i)
    vm_id=${OPTARG}
    test_configs id $vm_id && die "VM with ID: $vm_id not exist"
    ;;
    s)
    safe_flag="1"
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

configfile=$VMCONFIGDIR/vm-$vm_id-config.yml
configtemp=/tmp/vm-$vm_id-config.yml
workfile=/tmp/vm-$vm_id-move.$$

[[ ! -f $file ]] && die "cant't find config file for $file for vm-$vm_id"

vm_name=$(cat $file | $SCRIPTSDIR/yq r - name)
#vm_source=$(cat $file | $SCRIPTSDIR/yq r - target)
# don't consult about vm places with configs - scan hipervisors
vm_source=$(find_vm $vm_id)

[[ x${vm_source} == x${vm_target} ]] && die "cant't migrate vm-$vm_id under same hypervisor!"

# определеяем откуда удалять ВМ
src_=${BECOME_USER}@${SERVER_PREFIX}${vm_source}
SRCCONNECT="--connect qemu+ssh://$src_/system"
#echo $SRCCONNECT

# определеяем куда раземщать ВМ
dst_=${BECOME_USER}@${SERVER_PREFIX}${vm_target}
DSTCONNECT="--connect qemu+ssh://$dst_/system"
#echo $DSTCONNECT

# Запускаем все вольюмы на SRC system if not started (may happen if all vms are manualy deleted)
for pool_ in $( virsh $CONNECTSTRING pool-list --all | grep -i inactive | sed 's/^\s//' | cut -d' ' -f1 ); do
    virsh $SRCCONNECT pool-start $pool_ 2>&1 >/dev/null 
    virsh $SRCCONNECT pool-autostart $pool_ 2>&1 >/dev/null
done

# Запускаем все вольюмы на DST system if not started (may happen if all vms are manualy deleted)
for pool_ in $( virsh $CONNECTSTRING pool-list --all | grep -i inactive | sed 's/^\s//' | cut -d' ' -f1 ); do
    virsh $DSTCONNECT pool-start $pool_ 2>&1 >/dev/null 
    virsh $DSTCONNECT pool-autostart $pool_ 2>&1 >/dev/null
done

# ищем исходный  LVM вольюм на быстром разделе у нас они названы SSD или DATA1 - кто именно не важно
src_ssd_pool=$(virsh $SRCCONNECT pool-list 2>/dev/null | egrep 'DATA1|SSD' | cut -d' ' -f2 | head -1 )
# ищем исходный LVM вольюм на HDD разделе у нас они названы HDD или DATA2 - кто именно не важно
src_hdd_pool=$(virsh $SRCCONNECT pool-list 2>/dev/null | egrep 'DATA2|HDD' | cut -d' ' -f2 | head -1 )

# ищем конечный  LVM вольюм на быстром разделе у нас они названы SSD или DATA1 - кто именно не важно
dst_ssd_pool=$(virsh $DSTCONNECT pool-list 2>/dev/null | egrep 'DATA1|SSD' | cut -d' ' -f2 | head -1 )
# ищем конечный LVM вольюм на HDD разделе у нас они названы HDD или DATA2 - кто именно не важно
dst_hdd_pool=$(virsh $DSTCONNECT pool-list 2>/dev/null | egrep 'DATA2|HDD' | cut -d' ' -f2 | head -1 )

src_ssd_vols=$(virsh $SRCCONNECT vol-list $src_ssd_pool | grep vm-${vm_id} | grep -v clone | cut -d' ' -f2 )
src_hdd_vols=$(virsh $SRCCONNECT vol-list $src_hdd_pool | grep vm-${vm_id} | grep -v clone | cut -d' ' -f2 )

# копируем cidata
ssh $SSHOPTIONS $src_ sudo rsync -u --password-file=$RSYNC_SCR $CIDATADIR/vm-${vm_id}-cidata.iso $RSYNC_USER@${RSYNC_PREFIX}${vm_target}::$RSYNC_MODULE/tmp/
ssh $SSHOPTIONS $dst_ "sudo mv $TEMPDIR/vm-${vm_id}-cidata.iso $CIDATADIR/"


# if "running" - do live migrate
domstate=$(virsh $SRCCONNECT domstate vm-$vm_id | cut -d' ' -f1) 

echo ">>> $domstate <<<<"

# update VM config
ssh $SSHOPTIONS $src_ "sudo cat $configfile" | sed "s/^target:.*$/target: ${vm_target}/" > $configtemp

for i in $src_ssd_vols ; do
	vol_size=$(virsh $SRCCONNECT vol-list $src_ssd_pool --details | grep vm-${vm_id} | grep $i  | grep -v clone | awk '{ print int( $4 + "0,5555")}')
	
	virsh $DSTCONNECT vol-create-as "$dst_ssd_pool" "$i" "${vol_size}G" || \
	   die "can't create volume $i in pool: $dst_ssd_pool on $dst_"

##	virsh $DSTCONNECT vol-list $dst_ssd_pool

	if [ $domstate != 'running' ]; then
		echo "Copying volume data to destination"
		ssh $SSHOPTIONS $src_ "sudo dd if=/dev/$src_ssd_pool/$i bs=4M 2>/dev/null | { sleep 1; nc -w 5 ${SERVER_PREFIX}${vm_target} 9999; }" | \
		  ssh $SSHOPTIONS $dst_ "nc -w 6 -lp 9999 | pv -f -s ${vol_size}G | sudo dd bs=1024M of=/dev/$dst_ssd_pool/$i"
	fi
done

for i in $src_hdd_vols ; do
	vol_size=$(virsh $SRCCONNECT vol-list $src_hdd_pool --details | grep vm-${vm_id} | grep $i | grep -v clone | awk '{ print int($4 + "0,5555")}')
	
	virsh $DSTCONNECT vol-create-as "$dst_hdd_pool" "$i" "${vol_size}G" || \
	   die "can't create volume $i in pool: $dst_hdd_pool on $dst_"

#		virsh $DSTCONNECT vol-list $dst_hdd_pool

	if [ $domstate != 'running' ]; then
		echo "Copying volume data to destination"
		ssh $SSHOPTIONS $src_ "sudo dd if=/dev/$src_hdd_pool/$i bs=4M 2>/dev/null | { sleep 1; nc -w 5 ${SERVER_PREFIX}${vm_target} 9999; }" | \
		  ssh $SSHOPTIONS $dst_ "nc -w 6 -lp 9999 | pv -f -s ${vol_size}G | sudo dd bs=1024M of=/dev/$dst_hdd_pool/$i"
	fi
done


virsh $SRCCONNECT dumpxml vm-$vm_id 2>/dev/null | sed -e "s/$src_ssd_pool/$dst_ssd_pool/g" -e "s/$src_hdd_pool/$dst_hdd_pool/g" > $workfile

# развилка - если VM запущена мигрируем, если нет - нужно пересоздать из имеющегося описания и скопировать вольюмы
if [ "$domstate" = 'running' ]; then
	virsh $SRCCONNECT migrate --verbose --persistent --abort-on-error \
      	  --undefinesource \
	  --copy-storage-all \
	  --desturi "qemu+ssh://$dst_/system" \
	  --domain vm-$vm_id  \
	  --xml $workfile \
          --persistent-xml $workfile || die "can't live migrate vm"
fi

if [ "$domstate" = 'shut' ]; then
	# virsh used a local stored files!!! 
	virsh $DSTCONNECT define $workfile || die "cant' define new domain vm-$vm_id.xml from $(hostname):$workfile "
	virsh $SRCCONNECT undefine vm-$vm_id || die "cant't undefine vm-$vm_id.xml"
else
	die "vm state is $domstate - con't migrate it" 
fi

# копируем конфиг на все серверы группировки, кроме того где конфиг был создан
[[ -f $configtemp ]] && for hid in $(get_target_list); do
	rsync -u --password-file=$RSYNC_SCR $configtemp $RSYNC_USER@${RSYNC_PREFIX}${hid}::$RSYNC_MODULE/$VM_CONFIGS/
done

if false ; then
for i in $src_ssd_vols ; do
	virsh $SRCCONNECT vol-delete "$i"  --pool "$src_ssd_pool"  || \
	   die "can't delete volume $i in pool: $src_ssd_pool on $src_"
done

for i in $src_hdd_vols ; do
	virsh $SRCCONNECT vol-delete "$i"  --pool "$src_hdd_pool"   || \
	   die "can't delete volume $i in pool: $src_hdd_pool on $src_"
done
fi
# удаляем временные файлы
rm -f $configtemp
rm -f $workfile

