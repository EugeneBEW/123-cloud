#!/bin/bash

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh

export LANG=C
prog=$(basename $0)

vlans="$(virsh net-dumpxml ovs-network | grep '<portgroup' | sed -e "s/^.*='\(.*\)'>$/\1/g" )"

usage() {
       
cat <<__USAGE__	>&2

Usage: $prog  
generate unique currently free: id, ip, mac

__USAGE__
exit 1;
}	

vm_id=$(check_configs_id id)
echo Unused
echo id: $vm_id
for vl in $vlans; do
	vm_ip=$(get_uniq_ip $vl)
	vm_mac=$(gen_uniq_mac)

	printf "ip: %-24s mac: %-10s (vlan: %s)\n" $vm_ip $vm_mac $vl
done

