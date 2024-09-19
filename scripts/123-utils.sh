#!/bin/bash

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

export LANG=C

if [[ -z $VMCONFIGDIR ]]; then 
  #[[ -f $SCRIPTSDIR/123-defs.sh ]] && source $SCRIPTSDIR/123-defs.sh
  eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
fi

# Console output colors
bold() { echo -e "\e[1m$@\e[0m" ; }
red() { echo -e "\e[31m$@\e[0m" ; }
green() { echo -e "\e[32m$@\e[0m" ; }
yellow() { echo -e "\e[33m$@\e[0m" ; }

die() { red "ERR: $@" >&2 ; exit 2 ; }
silent() { "$@" > /dev/null 2>&1 ; }
output() { echo -e "- $@" ; }
outputn() { echo -en "- $@ ... " ; }
ok() { green "${@:-OK}" ; }

pushd() { command pushd "$@" >/dev/null ; }
popd() { command popd "$@" >/dev/null ; }

function parse_yaml {
   local file=$1 prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" $file  |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

ip2int()
{
    local a b c d
    { IFS=. read a b c d; } <<< $1
    echo $(((((((a << 8) | b) << 8) | c) << 8) | d))
}

int2ip()
{
    local ui32=$1; shift
    local ip n
    for n in 1 2 3 4; do
        ip=$((ui32 & 0xff))${ip:+.}$ip
        ui32=$((ui32 >> 8))
    done
    echo $ip
}

netmask()
# Example: netmask 24 => 255.255.255.0
{
    local mask=$((0xffffffff << (32 - $1))); shift
    int2ip $mask
}


broadcast()
# Example: broadcast 192.0.2.0 24 => 192.0.2.255
{
    local addr=$(ip2int $1); shift
    local mask=$((0xffffffff << (32 -$1))); shift
    int2ip $((addr | ~mask))
}

network()
# Example: network 192.0.2.0 24 => 192.0.2.0
{
    local addr=$(ip2int $1); shift
    local mask=$((0xffffffff << (32 -$1))); shift
    int2ip $((addr & mask))
}


mask2cidr() {

    local nbits dec
    local -a octets=( [255]=8 [254]=7 [252]=6 [248]=5 [240]=4
                      [224]=3 [192]=2 [128]=1 [0]=0           )
    
    while read -rd '.' dec; do
        [[ -z ${octets[dec]} ]] && die "Error: $dec is not recognised" 
        (( nbits += octets[dec] ))
        (( dec < 255 )) && break
    done <<<"$1."

    echo "$nbits"
}

# cidr - strat ip addr  / mask bits
function rnd2ip {
        local a b c d m

        { IFS=. read a b c d; } <<< $1
        { IFS=/ read d m; } <<< $d
        if [[ -z $m ]]; then
          m=$2
        fi

        local bits_=$(( 32 - $m))
        local mask_=$((0x0ffffffff << $bits_ ))
        local modulo_=$(((0x01 << $bits_ ) - 2))

        local start_=$(( $(ip2int $a.$b.$c.$d) & $mask_ ))

        local rnd_
        while : ; do
          rnd_=$(( $RANDOM % $modulo_))
          (( $rnd_ <= 10 )) || break;
        done
        #ip=$(( $start_ + $rnd_ ))

        echo $( int2ip  $(( $start_ + $rnd_ )))
}


calc_gateway()
{
  local  ip=$1

  OIFS=$IFS
  IFS='.' ; set $ip ; IFS=$OIFS
  echo "$1.$2.$3.1"
}

gen_mac()
{
   local start=${1:-'22:2f:e5'} #00:9f:6d
   local m1 m2 m3
   m1=$(cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=2 count=1 2>/dev/null)
   m2=$(cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=2 count=1 2>/dev/null)
   m3=$(cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=2 count=1 2>/dev/null)
   echo "$start:$m1:$m2:$m3"
}

convert_ip()
{
  local  ip=$1

  OIFS=$IFS
  IFS='.' ; set $ip ; ip1=$1 ; ip2=$2 ; ip3=$3 ;ip4=$4
  IFS='/' ; set $ip4 ; ip4=$1 ; IFS=$OIFS
  echo "$ip1.$ip2.$ip3.$ip4"
}

check_mask()
{
  local ip=$1/
  OIFS=$IFS

  IFS='/' ; set $ip ; mask=$2 ; IFS=$OIFS
  if [ -z $mask ] ; then 
 	echo $vm_mask 
  else
	echo $(netmask $mask)
  fi
}

function check_configs {
  local key_=$1 value_=$(echo $2 | sed 's|/.*$||')
  if [[ -d $VMCONFIGDIR/ ]]; then
    for file in $(find $VMCONFIGDIR/ -type f -name '*.yml' ) ; 
    do
      for cur_name in $(cat $file | $SCRIPTSDIR/yq r - $key_ ); 
        do
	  local x1=$(echo $cur_name | sed 's|/.*$||')
	  local x2=$(echo $value_ | sed 's|/.*$||')

          #if [[ $cur_name ==  $value_  ]]; then 
          if [[ $x1 ==  $x2  ]]; then 
            die "VM with $key_: $value_  already exixt... change the $key_ and try again"
          fi
      done
    done
  fi
}

function test_configs {
  local key_=$1 value_=$(echo $2 | sed 's|/.*$||')
  if [[ -d $VMCONFIGDIR/ ]]; then
    for file in $(find $VMCONFIGDIR/ -type f -name '*.yml' ) ; 
    do
      for cur_name in $(cat $file | $SCRIPTSDIR/yq r - $key_ ); 
        do
	        local x1=$(echo $cur_name | sed 's|/.*$||')
	        local x2=$(echo $value_ | sed 's|/.*$||')

          #if [[ $cur_name ==  $value_  ]]; then 
          if [[ $x1 ==  $x2  ]]; then 
            return -1;
          fi
      done
    done
  fi
  return 0;
}

function check_ip_address_exist {
	#check_configs 'networks.*.cidr' '172.20.5.8/16'
	check_configs 'networks.*.cidr' $1 
}

function check_configs_id {
  local key_ value_
  key_=$1
  shift
#set -x 
  if [ "$#" != "0" ]; then
    next_id=$1
    value_=$1
  fi

  if [[ -d $VMCONFIGDIR/ ]]; then
    next_id=${value_:-100}
    for file in $(find $VMCONFIGDIR/ -type f -name '*.yml' ) ; 
    do
      cur_id=$(cat $file | $SCRIPTSDIR/yq r - $key_)
      if [[ -z $value_ ]]; then 
        if (( cur_id >= next_id )); then 
          (( next_id=cur_id+1 ))
        fi
      else
        if [[ $next_id == $cur_id ]]; then 
          die "VM with $key_: $value_ already exist... change the $key_ and try again"
        fi
      fi
    done
  else
    next_id=100
  fi
echo $next_id
}

# param - network cidr - return - new cidr (not exist on network)
function get_uniq_ip {
 local portgroup_=$1
 shift
 local a b c d m
 local newip
 { IFS=. read a b c d; } <<< ${@:-$DEFAULTCIDR}
 { IFS=/ read d m; } <<< $d
 if [[ -z $m ]]; then
   m=24
 fi
 local bits_=$(( 32 - $m))
 local mask_=$((0x0ffffffff << $bits_ ))
 local modulo_=$(((0x01 << $bits_ ) - 2))

  [[ $#  == 0  ]] && case  $portgroup_ in 
  'vlan-5')
    c=5
    b=20
  ;;
  'vlan-8')
    c=8
    b=20
  ;;
  'vlan-100')
    c=100
  ;;
  'vlan-104')
    c=104
  ;;
  'vlan-108')
    c=108
  ;;
  'vlan-110')
    c=110
  ;;
  'vlan-112')
    c=112
  ;;
  *) 
    die "Wrong vlan tag number $portgroup"
  ;;
  esac

  local start_="$a.$b.$c.0/$m"
  local i=0
  while : ; 
  do
    (( i++ ))
    newip=$(rnd2ip $start_)
    $( test_configs 'networks.*.cidr' $newip ) && break;
    #if [[ $i -gt  $(( $modulo_*$modulo_ )) ]] ; then 
    if [[ $i -gt  $modulo_ ]] ; then 
      #die "Can't find free ip for $start_"
      newip=$( find_available_ip $start_ ) || die "can't find ip for $start_"
    fi
  done
  echo $newip/$m
}

function gen_uniq_mac {
  local i newmac

  while : ; 
  do
    (( i++ ))
    newmac=$(gen_mac)
    $( test_configs 'networks.*.mac' $newmac ) && break;
    if (( $i >  1000 )); then 
	die "can't generate uniq mac address..."
    fi
  done
  echo $newmac
}

function find_available_ip {
  local key_ value_
  key_='networks.*.cidr'
#  shift
  if [ "$#" != "0" ]; then
    next_id=$1
    value_=$next_id
    if [[ -d $VMCONFIGDIR/ ]]; then
      next_=$value_
      for file in $(find $VMCONFIGDIR/ -type f -name '*.yml' ) ; 
      do
        cur_id=$(cat $file | $SCRIPTSDIR/yq r - $key_)
        if [[ -z $value_ ]]; then 
          if (( cur_id >= next_id )); then 
            (( next_id=cur_id+1 ))
          fi
        else
          if [[ $next_id == $cur_id ]]; then 
            die "VM with $key_: $value_ already exist... change the $key_ and try again"
          fi
        fi
      done
    else
      next_id=100
    fi
  else 
    next_id='172.16.110.100/24'
    value_=$next_id
  fi
echo $next_id
}

function mkpasswd_hash {
  local password_=$1

  salt=$(cat /dev/urandom | tr -dc '[:alnum:]' | dd bs=4 count=2 2>/dev/null)
  echo $(openssl passwd -6 -salt ${salt}  $password_)
}

function mk_machineid {
  echo $(cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=4 count=10 2>/dev/null)
}


function check_target {
  local targets
  local value=$1

  readarray -t targets < <(eval 'echo "{$SERVERS}" | tr -cd "[[:digit:][:space:]]"')

  return $( [[ " ${targets[@]} " =~ " ${value} " ]] ) 
}

function get_target_list {
  local targets

  readarray -t targets < <(eval 'echo "{$SERVERS}" | tr -cd "[[:digit:][:space:]]"')
  echo " ${targets[@]} " 
}


function config_distribute {
  local hid
  local vm_id=$1 src_dir=$2
  local ret=0

  [[ -z $vm_id ]] && die "Distribute: empty vm_id"
  [[ -z $src_dir ]] && die "Distribute: non exixts directory"
  [[ -f $src_dir/vm-${vm_id}-config.yml ]] || die "Distribute: config file: $src_dir/vm-${vm_id}-config.yml not exist!"

# копируем конфиг на все серверы группировки, кроме того где конфиг был создан
  for hid in $SERVERS; do
    rsync -u --password-file=$RSYNC_SCR $src_dir/vm-${vm_id}-config.yml $RSYNC_USER@${hid}::$RSYNC_MODULE/$VM_CONFIGS/ || ret=$?
  done
return $ret
}

# удаляем конфиг со всех серверов группировки
function config_zap {
  local hid
  local vm_id=$1 src_dir=$2
  local ret=0

  [[ -z $vm_id ]] && die "Clean config: empty vm_id"
  [[ -z $src_dir ]] && die "Clean config: non exixt directory"
  [[ -f $src_dir/vm-${vm_id}-config.yml ]] || yellow "Clean config: $src_dir/vm-${vm_id}-config.yml not exist!"

  for hid in $SERVERS; do
    ssh $SSHOPTIONS ${BECOME_USER}@${hid} "sudo rm -f $src_dir/vm-${vm_id}-config.yml" || ret=$?
  done
  return $ret
}


function find_vm {
  local vm_id=$1
  local vm_target
  local connectstring
  local target_
  local targets

  [[ -z $vm_id ]] && die "find_vm: vm_id not provided"

  for vm_target in $SERVERS; do
        target_=${BECOME_USER}@${vm_target}
        connectstring="--connect qemu+ssh://$target_/system"

        virsh $connectstring list --all | grep vm-$vm_id > /dev/null
        if [ $? -eq 0 ]; then
		echo $vm_target; 
		return 0;
        fi
done
die "find_vm:  can't find vm-$vm_id on hypervisors $SERVERS"
}

# vi: set expandtab sw=2 ts=2
