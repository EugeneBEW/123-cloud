#!/bin/bash
#
#

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh

export LANG=C
prog=$(basename $0)

function dom_ether {
local val=$1
local cidr vlan mac

local ret
   #  --network network=ovs-network,portgroup=\"$vm_vlan\",mac=\"$vm_mac\",model=virtio
   set $( echo $val | sed -e 's#^\([0-9./]*\):\(.*\)[/=]\(.*\)$#\1 \2 \3#' -e 's#^\([0-9./]*\):\(.*\)$#\1 \2#' )
   cidr=$1
   [ -z $cidr ] && die "ETH: no cidr"
   check_configs 'networks.*.cidr' $cidr

   vlan=$2
   [ -z $vlan ] && die "ETH: no vlan"

   mac=$3
   [[ -z $mac ]] && mac=$(gen_uniq_mac) || check_configs 'networks.*.mac' $mac

   printf -v ret " --network network=ovs-network,portgroup=\"%s\",mac=\"%s\",model=virtio" "$vlan" "$mac"
   echo $ret
}


usage() {

images="$(ls /var/123-cloud/images/ | sed -e "/$DEFAULTIMAGE/s/^/* /" -e 's/^/   /')"
vlans="$(virsh net-dumpxml ovs-network | grep '<portgroup' | sed -e "s/$DEFAULTVLAN/* $DEFAULTVLAN/" -e "s/^.*='\(.*\)'>$/   \1/g" )"
       
cat <<__USAGE__	>&2

Usage: $prog [-n vm_name] -c vcpu  -r vram(GB) [-b boot_disk_size(GiB)] [-t target_server] [-i <vm_id>] 
             [-v vlan_name ] [-a <vm_ip>/<mask bits>] [-m <vm_mac>] 
	     [-d data_ssd_size(GiB)] [-s data_hdd_size(GiB)]
	     [-1 <eth1_ip>/mask:vlan[=mac]]
	     [-2 <eth2_ip>/mask:vlan[=mac]]
	     [-3 <eth3_ip>/mask:vlan[=mac]]
             [-I raw_image]  
vlans (* - default):
$vlans

raw images (* - default): 
$images
__USAGE__
exit 1;
}	

vm_id=$(check_configs_id id)
vm_name="vm-$vm_id"
vm_vlan=$DEFAULTVLAN
vm_net=$DEFAULTCIDR
#vm_mac=''
vm_boot='10'

vm_target=$(hostname | tr -cd '[:digit:]')

vm_image=$DEFAULTIMAGE

while getopts ":n::c:r:b::i::v::a::m::I::t::d::s::1::2::3::" o; do
  case "${o}" in
    n)
    vm_name=${OPTARG}
    check_configs 'name' $vm_name 
    #(($v == 45 || $v == 90)) || usage
    ;;
    c)
    vm_cpu=${OPTARG}
    (($vm_cpu >= 1 && $vm_cpu <= 64 )) || die "wrong cpu numbers ( availble 1 < ...< 64 ): $vm_cpu..." 
    ;;
    r)
    vm_ram=${OPTARG}
    (($vm_ram >= 2 && $vm_ram <= 128 )) || die "wrong ram size ( availble 2 < ...< 128 ): $vm_ram..." 
	vm_ram=$(($vm_ram * 1024))
    ;;
    b)
    vm_boot=${OPTARG}
    (($vm_boot >= 6 && $vm_boot <= 200)) || die "wrong boot disk size ( availble 6 < ...< 200 ): $vm_boot..." 
    ;;
    i)
    vm_id=$(check_configs_id id ${OPTARG} )
    ;;
    v)
    vm_vlan=${OPTARG}
    #check_configs 'networks.*.portgroup' $vm_vlan 
    ;;
    a)
    vm_ip=${OPTARG}
    check_configs 'networks.*.cidr' $vm_ip
    ;;
    1)
    vm_eth1=${OPTARG}
    ;;
    2)
    vm_eth2=${OPTARG}
    ;;
    3)
    vm_eth3=${OPTARG}
    ;;
    m)
    vm_mac=${OPTARG}
    check_configs 'networks.*.mac' $vm_mac
    ;;
    I)
    vm_image=${OPTARG}
    [[ -f $IMAGESDIR/$vm_image ]] || die "image $vm_image doesn't exists..."
    ;;
    t)
    vm_target=${OPTARG}	
    check_target $vm_target || die "wrong target server number: $vm_target..."
    ;;
    d)
    vm_data_ssd=${OPTARG}
    ;;
    s)
    vm_data_hdd=${OPTARG}
    ;;
    *)
    usage
    ;;
  esac
done
shift $((OPTIND-1))

if [ -z "${vm_ram}" ] || [ -z "${vm_cpu}" ]; then
    usage
fi
#
[[ -z $vm_ip ]] && vm_ip=$(get_uniq_ip $vm_vlan)
[[ -z $vm_mac ]] && vm_mac=$(gen_uniq_mac)

[[ "x$vm_id" != "x" ]] || die "empty id..."

[[ -n $vm_eth1 ]] && {
     vm_eth1=$(dom_ether $vm_eth1)
}

[[ -n $vm_eth2 ]] && {
     vm_eth2=$(dom_ether $vm_eth2)
}

[[ -n $vm_eth3 ]] && {
     vm_eth3=$(dom_ether $vm_eth3)
}

# определеяем куда размещать ВМ
target_=${BECOME_USER}@${SERVER_PREFIX}${vm_target}
CONNECTSTRING="--connect qemu+ssh://$target_/system"

# create PROTO config
eval "cat <<_EOF_
$(<$TEMPLATESDIR/vm-config.yml)
_EOF_
" 2> /dev/null > $TEMPDIR/vm-$vm_id-config.yml && pass='1: create yaml VM config done'
echo $pass

$SCRIPTSDIR/123-gen-cidata-iso.sh -i $vm_id -n $vm_name -a $vm_ip -m $vm_mac 2>&1 >/dev/null && pass='2: create cidata iso done'
echo $pass

# копируем gold_image на все серверы группировки, проверяя что их действительно нужно копировать
for hid in $(get_target_list); do
	creds="$BECOME_USER@$SERVER_PREFIX${hid}"
	test -f $IMAGESDIR/$vm_image || die "VM Image: $vm_image doesn't exist on $(hostname) server. Download it befor use to $IMAGESDIR!" 
	ssh $SSHOPTIONS $creds "sudo test -f $IMAGESDIR/$vm_image" || \
		( scp $SSHOPTIONS $IMAGESDIR/$vm_image $creds:/tmp && ssh $SSHOPTIONS  $creds "sudo mv /tmp/$vm_image $IMAGESDIR/" )
done && pass='3: copy gold image to all nodes except source'
echo $pass


# Запускаем все вольюмы на target system if not started (may happen if all vms are manualy deleted)
for pool_ in $( virsh $CONNECTSTRING pool-list --all | grep -i inactive | sed 's/^\s//' | cut -d' ' -f1 ); do
    virsh $CONNECTSTRING pool-start $pool_ 2>&1 >/dev/null 
    virsh $CONNECTSTRING pool-autostart $pool_ 2>&1 >/dev/null
done

# !!! TODO
# ищем подходящий LVM вольюм на быстром разделе у нас они названы SSD или DATA1 - кто именно не важно
pool=$(virsh $CONNECTSTRING pool-list 2>/dev/null | egrep 'DATA1|SSD' | cut -d' ' -f2 | head -1 ) && pass='3: dest for boot disk found'
echo $pass
virsh $CONNECTSTRING vol-list $pool  2>&1 >/dev/null || die "cant list volumes on target: $target_"
vol_=$( virsh $CONNECTSTRING vol-list $pool 2>/dev/null | grep vm-${vm_id}-boot  | grep -v clone  )

# создаем LVM вольюм в быстром разделе ( ssd или data1  )
# create boot_disk
[[ -z "$vol_" ]] || die "artefact volume vm-${vm_id}-boot exist on $target_. at first remove or rename it manualy." 
virsh $CONNECTSTRING vol-create-as "$pool" "vm-${vm_id}-boot" "${vm_boot}G" || die "can't create volume vm-${vm_id}-boot in pool: $pool on $target_"

#  ssh $SSHOPTIONS $target_ "yes | sudo lvcreate -W y -L ${vm_boot}G -n vm-${vm_id}-boot $pool" && pass='4 BOOT disk created'

# copy image to volume
# заливаем image на созданный виртуальный диск
ssh  $SSHOPTIONS $target_ "sudo dd if=$IMAGESDIR/$vm_image of=/dev/$pool/vm-${vm_id}-boot bs=512K 2>/dev/null" && pass='5: BOOT disk copied'
echo $pass

if [[ ! -z $vm_data_ssd ]]; then
    pool1=$(virsh $CONNECTSTRING pool-list 2>/dev/null | egrep 'DATA1|SSD' | cut -d' ' -f2 | head -1 ) || die "can't find pool for data1 disk"
    virsh $CONNECTSTRING vol-list $pool1  2>&1 >/dev/null || die "cant list volumes in $pool1 on target: $target_"
    vol_=$( virsh $CONNECTSTRING vol-list $pool1 2>/dev/null | grep vm-${vm_id}-data1  | grep -v clone  )
    [[ -z "$vol_" ]] || die "artefact volume vm-${vm_id}-data1 exist on $target_. remove or rename it manualy." 
    virsh $CONNECTSTRING vol-create-as "$pool1" "vm-${vm_id}-data1" "${vm_data_ssd}G" || die "can't create volume vm-${vm_id}-data1 in pool: $pool1 on $target_"
    disk1=" --disk /dev/$pool1/vm-${vm_id}-data1,device=disk,bus=virtio "
    
    pass='5: SSD create' 
    echo $pass
fi

if [[ ! -z $vm_data_hdd ]]; then
    pool2=$(virsh $CONNECTSTRING pool-list 2>/dev/null | egrep 'DATA2|HDD' | cut -d' ' -f2 | head -1 ) || die "can't find pool for data2 disk"
    virsh $CONNECTSTRING vol-list $pool2  2>&1 >/dev/null || die "cant list volumes in $pool2 on target: $target_"
    vol_=$( virsh $CONNECTSTRING vol-list $pool2 2>/dev/null | grep vm-${vm_id}-data2  | grep -v clone  )
    [[ -z "$vol_" ]] || die "artefact volume vm-${vm_id}-data2 exist on $target_. remove or rename it manualy." 
    virsh $CONNECTSTRING vol-create-as "$pool2" "vm-${vm_id}-data2" "${vm_data_hdd}G" || die "can't create volume vm-${vm_id}-data2 in pool: $pool2 on $target_"
    disk2=" --disk /dev/$pool2/vm-${vm_id}-data2,device=disk,bus=virtio "
    
    pass='5: HDD create' 
    echo $pass
fi

# копируем cidata на все серверы группировки, проверяя что их действительно нужно копировать 
#(обходим тот server где конфиг был создан)
for hid in $(get_target_list); do
	rsync -u --password-file=$RSYNC_SCR $TEMPDIR/vm-${vm_id}-cidata.iso $RSYNC_USER@${RSYNC_PREFIX}${hid}::$RSYNC_MODULE/tmp/
done && pass="6: copy cidata to all nodes... pass"
echo $pass

for hid in $(get_target_list); do
	ssh  $SSHOPTIONS ${BECOME_USER}@${SERVER_PREFIX}${hid} "sudo mv $TEMPDIR/vm-${vm_id}-cidata.iso $CIDATADIR/"
done && pass="6: move cidata to libvirt volume dir in all nodes... pass"
echo $pass

echo "Create VM on $target node"

virt-install  $CONNECTSTRING \
  --name vm-$vm_id \
  --metadata title=vm-$vm_id\($vm_name\) \
  --disk /dev/$pool/vm-${vm_id}-boot,device=disk,bus=virtio \
  --disk $CIDATADIR/vm-$vm_id-cidata.iso,device=cdrom \
  $disk1 \
  $disk2 \
  --os-variant=alse17 \
  --virt-type kvm \
  --vcpus \"${vm_cpu}\" \
  --memory \"${vm_ram}\" \
  --network network=ovs-network,portgroup=\"$vm_vlan\",mac=\"$vm_mac\",model=virtio \
  $vm_eth1 \
  $vm_eth2 \
  $vm_eth3 \
  --console pty,target_type=serial \
  --import \
  --noreboot \
  --noautoconsole \
 2>&1 >/dev/null && pass="8: vm with id $vm_id and name $vm_name created on $target..."

# копируем конфиг на все серверы группировки, кроме того где конфиг был создан
for hid in $(get_target_list); do
	rsync -u --password-file=$RSYNC_SCR $TEMPDIR/vm-${vm_id}-config.yml $RSYNC_USER@${RSYNC_PREFIX}${hid}::$RSYNC_MODULE/$VM_CONFIGS/
done && pass='7: propagate config to all nodes'
echo $pass

#virsh -c qemu+ssh://fgisuadmin@server2/system desc vm-101 --title 'vm-101 zookeeper1'
#echo vm_name=${vm_name} vm_cpu=${vm_cpu} vm_ram=${vm_ram} vm_boot=${vm_boot} vm_id=${vm_id} vm_vlan=${vm_vlan} vm_ip=${vm_ip} vm_mac=${vm_mac} vm_image=${vm_image} vm_target=${vm_target}	

#workdir=/tmp/vm-create.$$
#mkdir $workdir

# vim: ts=2 sw=2 et :
