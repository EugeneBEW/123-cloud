#!/bin/bash
#set -x

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh
[[ -f $SCRIPTSDIR/123-init.sh ]] && source $SCRIPTSDIR/123-init.sh

export LANG=C
prog=$(basename $0)


usage() { echo "Usage: $0 -i <vm_id> -n <vm_name> -a <vm_ip>/<mask bits> -m <vm_mac>" 1>&2; exit 1; }

. $DEFAULTCFG

while getopts ":i:n:a:m:" o; do
    case "${o}" in
        i)
            vm_id=${OPTARG}
            #(($v == 45 || $v == 90)) || usage
            ;;
        n)
            vm_name=${OPTARG}
            ;;
        a)
            vm_ip=${OPTARG}
            ;;
        m)
            vm_mac=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z "${vm_id}" ] || [ -z "${vm_name}" ] || [ -z "${vm_ip} " ]; then
    usage
fi

#passwd_hash=$(mkpasswd_hash $vm_password)
passwd_hash=$vm_password
uid=$(mk_machineid)

workdir=/tmp/vm-$vm_id-cidata.$$
mkdir $workdir

cat <<EOF >$workdir/meta-data
instance-id: $uid
EOF

#test -z $vm_gateway && vm_gateway=$(calc_gateway $vm_ip)
#vm_mac=$(gen_mac)

cvm_ip=$(convert_ip $vm_ip)
cvm_mask=$(check_mask $vm_ip)

intmask=$(mask2cidr $cvm_mask )
vm_network=$(network $cvm_ip $intmask)
vm_gateway=$(calc_gateway $vm_network)

cat <<EOF >$workdir/network-config
version: 1
config:
    - type: physical
      name: eth0
      mac_address: '${vm_mac}'
      subnets:
      - type: static
        address: '${cvm_ip}'
        netmask: '${cvm_mask}'
        gateway: '${vm_gateway}'
    - type: nameserver
      address:
      - '${vm_ns1}'
      - '${vm_ns2}'
      search:
      - '${vm_domain}'
EOF

cat <<EOF >$workdir/user-data
#cloud-config
hostname: ${vm_name}
manage_etc_hosts: true
fqdn: ${vm_name}.${domain}
user: ${vm_user}
password: ${passwd_hash} 
ssh_authorized_keys:
EOF

cat $AUTHDIR/authorized_keys | sed 's/^/  - /' >>  $workdir/user-data

cat <<EOF >>$workdir/user-data
chpasswd:
  expire: False
users:
  - default
package_upgrade: false
EOF

cat <<EOF >$workdir/vendor-data
EOF

pushd .
cd /tmp

genisoimage  -quiet -input-charset utf-8 -output vm-${vm_id}-cidata.iso -volid cidata -joliet -rock $workdir/user-data $workdir/meta-data $workdir/network-config $workdir/vendor-data 

chown  $CLOUD_USER:$CLOUD_USER vm-${vm_id}-cidata.iso
mv vm-${vm_id}-cidata.iso $TEMPDIR
rm -rf $workdir

popd 
# vim: ts=2 sw=2 et :
