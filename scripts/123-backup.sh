#!/usr/bin/env bash
#
INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh

BACKUPSERVER=172.16.104.21

export LANG=C

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



backup_jobs=$(ssh $SSHOPTIONS $target_ sudo LD_LIBRARY_PATH=/opt/rubackup/lib /opt/rubackup/bin/rb_schedule | grep vm-$vm_id | awk '{  print $1; }')

for j in $backup_jobs; do 
    yellow "Start global backup job #$j for vm-$vm_id"
    ssh $SSHOPTIONS ${BECOME_USER}@${BACKUPSERVER} sudo LD_LIBRARY_PATH=/opt/rubackup/lib /opt/rubackup/bin/rb_global_schedule -x $j
done

done_flag=0

yellow "wait for task complete"

until (( $done_flag == 1 )); do
    ssh $SSHOPTIONS $target_ "sudo LD_LIBRARY_PATH=/opt/rubackup/lib /opt/rubackup/bin/rb_tasks " | \
	grep vm-$vm_id | egrep -i 'Execution' >/dev/null || { done_flag=1; break; }
    sleep 5; echo -n "."
done


