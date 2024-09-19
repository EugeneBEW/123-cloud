#!/bin/bash
#


INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh

usage() { echo "Usage: $prog [-h usage] [-i <vm_id>] [-t <target>]
       get staus of vm's in cluster" 1>&2; exit 1; }

export LANG=C
prog=$(basename $0)

readarray -t targets < <(eval echo "$(get_target_list)")

while getopts ":i::t:" o; do
  case "${o}" in
    t)
    vm_target=${OPTARG}	
    check_target $vm_target || die "wrong target server number: $vm_target..." 
    
    targets=$vm_target
    ;;
    i)
    vm_id=${OPTARG//vm-/}
    test_configs id $vm_id && die "VM with ID: $vm_id not exist"
    ;;
    *)
    usage
    ;;
  esac
done
shift $((OPTIND-1))


show_long_vminfo() {
local dom=$2
local vm_target=$1

local target vm_target CONNECTSTRING vminfo title state i

[[ ! -z $dom ]] && [[ ! -z $vm_target ]] && \
  {
  target_=${BECOME_USER}@${SERVER_PREFIX}${vm_target}
  CONNECTSTRING="--connect qemu+ssh://$target_/system"

    title=$(virsh $CONNECTSTRING dumpxml --xpath "//title" $dom \
    | sed -e 's/<title>//g' -e 's/<\/title>//g')

    readarray -t vminfo < <( \
    echo "HV: $(virsh $CONNECTSTRING hostname)"
    echo "Name: $title"
    virsh $CONNECTSTRING "dominfo $dom" \
      | egrep -v 'UUID|Id|OS Type|Security|Persistent|Managed|time|Autostart|Used' \
      | sed -e 's/^\([A-Za-z].*\):\s\+\([0-9]\+\)\sKiB.*$/\1: \2/' -e 's/\s\+/ /g' -e 's/Name/ID/' \
      | awk '/memory/ { print  $1 " " $2 " " $3/1024/1024 ; }; !/memory/ { print $0 }' \
    )

    for i in "${vminfo[@]}"; do
	echo "$i" | egrep 'Name:' >/dev/null 
	[[ $? -eq 0 ]] && printf "%-32s" "$i" || printf "%-18s " "$i"
    done
    echo 
  }
}


[[ -z $vm_id || -n $vm_target ]] && for vm_target in ${targets[@]}; do
	target_=${BECOME_USER}@${SERVER_PREFIX}${vm_target}
	CONNECTSTRING="--connect qemu+ssh://$target_/system"
	echo "-------------------------------"
	echo "hypervisor: $vm_target"

	echo "----------- mem ---------------"

	readarray -t node < <(virsh $CONNECTSTRING nodememstats | sed 's/^\([a-z].*\):\s\+\([0-9]\+\).*$/\1 \2/' | awk '{ print " " $1 " " $2/1024/1024 " GiB";}')
	printf "%-25s" "${node[@]}"; echo; 
	echo "---------- disks --------------"


	# Запускаем все вольюмы на target system if not started (may happen if all vms are manualy deleted)
        for pool_ in $( virsh $CONNECTSTRING pool-list --all | grep -i inactive | sed 's/^\s//' | cut -d' ' -f1 ); do
            virsh $CONNECTSTRING pool-start $pool_ 2>&1 >/dev/null
            virsh $CONNECTSTRING pool-autostart $pool_ 2>&1 >/dev/null
        done


        src_ssd_pool=$(virsh $CONNECTSTRING pool-list  2>/dev/null | egrep 'DATA1|SSD' | cut -d' ' -f2 | head -1 )
        src_hdd_pool=$(virsh $CONNECTSTRING pool-list  2>/dev/null | egrep 'DATA2|HDD' | cut -d' ' -f2 | head -1 )

	readarray -t pools < <(virsh $CONNECTSTRING pool-info $src_ssd_pool | egrep -i 'name|capacity|allocation|available'| sed 's/  / /g')
	printf "%-25s" "${pools[@]}"; echo;

	readarray -t pools < <(virsh $CONNECTSTRING pool-info $src_hdd_pool | egrep -i 'name|capacity|allocation|available'| sed 's/  / /g')
	printf "%-25s" "${pools[@]}"; echo;
	echo "----------- vms ---------------"

	#virsh $CONNECTSTRING list --title --all | grep vm- 
	for i in $(virsh $CONNECTSTRING list --name --all); do
		show_long_vminfo $vm_target $i
	done

	echo "----------- end ---------------"
	echo
done 

[[ ! -z $vm_id ]] && for vm_target in ${targets[@]}; do
	target_=${BECOME_USER}@${SERVER_PREFIX}${vm_target}
	CONNECTSTRING="--connect qemu+ssh://$target_/system"

	virsh $CONNECTSTRING list --all | grep vm-$vm_id > /dev/null
	if [ $? -eq 0 ]; then 
		echo 'Virtual Machine:'
		show_long_vminfo $vm_target vm-$vm_id | tee /dev/tty | grep 'running' > /dev/null && state='running'
		echo 'Network:'

		readarray -t ethers < <( \
		virsh $CONNECTSTRING dumpxml --xpath "//devices/interface/mac//@address|//devices/interface/source//@portgroup" vm-$vm_id \
		| sed -e 'N;s/\n/ /' -e 's/^\s.*address=//' -e 's/"//ig' -e 's/portgroup=//' -e 's/  / /g');

		[[ $state == "running" ]] && \
			{ 
			readarray -t ethers2 < <(virsh $CONNECTSTRING domifaddr vm-$vm_id  --source agent | grep '\seth[0-9]*') ;
			for i in "${ethers2[@]}"; do
				for y in "${ethers[@]}" ; do
					OFS=$IFS; IFS=' '
					read -r mac port <<< $y
					[[ -z $mac ]] && continue;
					IFS=$OFS
					echo $i | grep $mac >/dev/null && echo "$i $port"
				done
			done
		} || echo "${ethers[@]}"
	echo 'Disks:'
	virsh $CONNECTSTRING "domblkinfo vm-$vm_id --all --human; "
	fi
done 

# vi: set expandtab sw=2 ts=2
