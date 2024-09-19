#!/usr/bin/env perl

use v5.28;
use strict;
use warnings;
use XML::Simple;
use YAML::Tiny;
use Getopt::Std;
use File::Basename;
use Sys::Virt;
use Sys::Virt::Error;
use Sys::Virt::Domain;
use Sys::Virt::StoragePool;
use Sys::Virt::StorageVol;

use Scalar::Util qw(looks_like_number);

use Cwd;
use File::Temp;

use lib '/var/123-cloud/scripts';
use utils qw(get_default get_all_hv);

#my $parser = new XML::Simple;
#my $addr = @ARGV ? shift @ARGV : "";
#
my %options=();
getopts("ht:n:i:c:r:b:d:s:0:1:2:3:I:v:o:", \%options);

my $prog = basename($0);
my $usage=<<_USAGE_;

  usage: $prog [-h]|-n <vm_name> [ -t target ] [ -i <vm_id> ] -c <vm_vcpus>  -r <vm_mem_in_GiB> -b <vm_boot_disk_in_GiB> 
  	       [ -d data_ssd_size_in_GiB] [ -s data_hdd_size_in_GiB]
               [ -0 <vm_ip0>[/<mask_bits0>[:vm_mac0]]] 	- eth0 - may be defaults 
               [ -1 <vm_ip1>[/<mask_bits1>[:vm_mac1]]] 	- eth1
               [ -2 <vm_ip2>[/<mask_bits2>[:vm_mac2]]] 	- eth2
               [ -3 <vm_ip3>[/<mask_bits3>[:vm_mac3]]] 	- eth3
               [-I raw_image]
               [-o your-os-variant]
               [-V virt-type]

	       VM_IP: it is possible to place desired network only or exact ip... 
	       raw_image: must be exist in imagedir before use... 
	       os-variant: alse17 is default, directly passed to virt-install
	       virt-type: kvm is default, directly passed to virt-install
_USAGE_




die $usage if defined $options{h} || not defined $options{n} || not defined $options{c} || not defined $options{r} || not defined $options{b};
die $usage . "\nERROR wrong cpu number\n" if not looks_like_number($options{c});
die $usage . "\nERROR wrong ram number\n" if not looks_like_number($options{r});

my ( $boot, $ssd, $hdd );
die $usage . "\nERROR wrong boot size\n" if not looks_like_number( $boot = $options{b} );
die $usage . "\nERROR wrong boot size\n" if defined $options{d} and not looks_like_number( $ssd = $options{d} );
die $usage . "\nERROR wrong boot size\n" if defined $options{s} and not looks_like_number( $hdd = $options{s} );

my $networks_section;
my $disks_section;
my $xml;

my $vm_name = $options{n};
my $vm_vcpu = $options{c};
my $vm_ram = $options{r};
my $vm_id;
my $os_variant=$options{o} || "alse17";
my $virt_type=$options{V} || "kvm";

my $host = utils::get_target($options{t});
my $host_num = utils::get_target_num($options{t});
#my $libvirt_uri="--connect qemu+ssh://". &get_default('become_user') . "\@$host/system";
my $become_user=get_default('become_user');
my $libvirt_uri="qemu+ssh://". &get_default('become_user') . "\@$host/system";
my $rootdir = get_default('rootdir');
my $tempdir = get_default('tmp');
my $vmconfigdir = get_default('vm_configs');
my $cidatadir = get_default('cidata');
my $imagesdir = get_default('images');
my $ssd_prefix = get_default('ssd_prefix');
my $hdd_prefix = get_default('hdd_prefix');
my $image = $imagesdir. "/" . ( ( not defined $options{'I'} )? get_default('defaultimage') : $options{'I'} );

my $user = utils::get_user_name();
my $password = utils::get_user_password();
my $ssh_authorized_keys = utils::get_ssh_authorized_keys();
my $domain = utils::get_domain();
my $fqdn = ($vm_name =~ m/\./ )? $vm_name : $vm_name.".".$domain;

die "ERROR: unpropriate vcpus number <$vm_vcpu> use 1 - 24 only\n" if ( $vm_vcpu < 1 || $vm_vcpu > 24 );
die "ERROR: unpropriate vram <$vm_ram> use 1 - 48 GB only\n" if ( $vm_ram < 1 || $vm_ram > 48 );

$vm_ram *=1024;

if ( defined $options{i} ){
	die "ERROR: VM_ID already used\n" if utils::vmid_check($options{i});
	$vm_id = $options{i};
} else {
	$vm_id = utils::get_uniq_id();
}

# определеяем куда размещать ВМ
  #become_user: cloud
  #rsync_user:  123-cloud
my @interfaces;
for ( my $i=0; $i < 4 ; $i++ ) {
	push ( @interfaces, [ "eth$i", utils::parse_address_string ( $options{"$i"})] ) if defined $options{"$i"};
}

my $machine_id = utils::gen_machineid();
my $meta_data = <<_META_DATA_
machine-id: $machine_id
_META_DATA_
;
my $vendor_data = <<_VENDOR_DATA_
_VENDOR_DATA_
;
# "eth0", ( vlan, address, ip->mask(), ip->masklen(), mac, portgroup, gateway, $d, $c, $b, $a );
my $network_config = <<_NETWORK_CONFIG_
version: 1
config:
_NETWORK_CONFIG_
;
foreach (@interfaces) {

$networks_section .= " --network network=ovs-network,portgroup=\"". @{$_}[6] ."\",mac=\"". @{$_}[5] ."\",model=virtio ";

$network_config .= <<_ETH_
    - type: physical
      name: @{$_}[0]
      mac_address: '@{$_}[5]'
      subnets:
      - type: static
        address: '@{$_}[2]'
        netmask: '@{$_}[3]'
        gateway: '@{$_}[7]'
_ETH_
;
}
# TODO...
$network_config .= <<_NAMESERVER_
    - type: nameserver
      address:
      - '172.16.110.151'
      - '172.16.110.139'
      search:
      - 'geop4.local'
_NAMESERVER_
;

my $user_data .= <<_USER_DATA_
#cloud-config
hostname: $vm_name
manage_etc_hosts: true
fqdn: $fqdn
user: $user
password: $password 
ssh_authorized_keys:
$ssh_authorized_keys
chpasswd:
  expire: False
users:
  - default
package_upgrade: false
_USER_DATA_
;

my $vm_config .= <<_VM_CONFIG_
---
id: $vm_id
name: $vm_name
target: $host_num
state: notused
status: notused
vcpus: $vm_vcpu
memory: $vm_ram
cidata: vm-$vm_id-cidata.iso
os-variant: alse17
virt-type: kvm
volumes:
- id: boot
  type: ssd
  size: ${boot}G
_VM_CONFIG_
;

$vm_config .= <<_VM_CONFIG_
- id: data1
  type: ssd
  size: ${ssd}G
_VM_CONFIG_
if ${ssd};

$vm_config .= <<_VM_CONFIG_
- id: data2
  type: hdd
  size: ${hdd}G
_VM_CONFIG_
if ${hdd};

$vm_config .= "networks:\n";
# "eth0",  vlan, address, ip->mask(), ip->masklen(), mac, portgroup, gateway, $d, $c, $b, $a ;
foreach (@interfaces) {
$vm_config .= <<_ETH_
- id: @{$_}[0]
  cidr: @{$_}[2]/@{$_}[4]
  network: ovs-network
  portgroup: @{$_}[6]
  mac: @{$_}[5]
  model: virtio
_ETH_
;
}
# create files in 123-cloud/tmp dir
{
    print "INFO: Create cloud-config ISO image: vm-$vm_id\n";
    my $fh;
    my $oldcwd = getcwd;

    my $workdir = File::Temp->newdir;
    chdir $workdir;

    open $fh, '>', 'meta-data';
    print {$fh} $meta_data."\n";
    close $fh;

    open $fh, '>', 'user-data';
    print {$fh} $user_data."\n";
    close $fh;

    open $fh, '>', 'network-config';
    print {$fh} $network_config."\n";
    close $fh;

    open $fh, '>', 'vendor-data';
    print {$fh} "\n";
    close $fh;

    chdir '/tmp';

    `genisoimage  -quiet -input-charset utf-8 -output vm-${vm_id}-cidata.iso -volid cidata -joliet -rock $workdir/user-data $workdir/meta-data $workdir/network-config $workdir/vendor-data && mv vm-${vm_id}-cidata.iso $tempdir`;

    open $fh, '>', "$tempdir/vm-${vm_id}-config.yml";
    print {$fh} $vm_config, "\n";
    close $fh;
	
    chdir $oldcwd;
}

# копируем gold_image на все серверы группировки, проверяя что их действительно нужно копировать
die "ERROR: gold image $image is not exist on current hypervisor, can't copy it to other...\n" if not -f $image;
foreach my $target ( get_all_hv() ) {
	my $ruser = get_default ('rsync_user');
	my $rscr = get_default ('rsync_scr');
	my $module = get_default ('rsync_module');
	my $rdst = get_default('images') =~ s#$rootdir/##r;
	print "    ", $target," \n";
	system( "rsync -u --info=name1 --password-file=$rscr $image $ruser\@${target}::${module}/$rdst");
}

my $conn;
my @pools;

print "INFO: connect to hypervisor $host\n";
eval { $conn = Sys::Virt->new(uri => $libvirt_uri); };
if ($@) {
  die "Unable to open connection to $host" . $@->message . "\n";
}
eval { @pools = $conn->list_all_storage_pools(); };
if ($@) {
  die "Unable to get list of pools on $host" . $@->message . "\n";
}

my $ssd_pool;
my $hdd_pool;

print "INFO: starting all pools on $host\n";
eval { 
    foreach my $pool ( @pools ) {
	    my $name = $pool->get_name();

	    $pool->set_autostart( 1 ) if not ( $name =~ m/default/ );

	    $ssd_pool = $pool if $name =~ m/$ssd_prefix/;
	    $hdd_pool = $pool if $name =~ m/$hdd_prefix/;

	# Запускаем все нужные вольюмы на target system if defined but not started (may happen if all vms are manualy deleted)
	    if ( not $pool->is_active() ) {
		$pool->create() if $name =~ m/$ssd_prefix/;
		$pool->create() if $name =~ m/$hdd_prefix/;
		$pool->create() if $name =~ m/cidata/;

	    }
    }
};
if ($@) {
  die "Unable to start pools on $host" . $@->message . "\n";
}

die "ERROR: can't find desired pools $ssd_prefix or $hdd_prefix on $host\n" if (not $ssd_pool) || (not $hdd_pool);

print "INFO: ckeck existence of volumes on $host\n";
my @volumes;
eval {
    @volumes = ( $ssd_pool->list_all_volumes() , $hdd_pool->list_all_volumes());
};
if ($@) {
  die "ERROR: Unable to start pools on $host" . $@->message . "\n";
}
foreach ( @volumes ) { 
    my $volname = $_->get_name();

    die "ERROR: volume: $volname exist on target $host. Remove it before creating vm!\n" if $volname eq "vm-".$vm_id."-boot";
    die "ERROR: volume: $volname exist on target $host. Remove it before creating vm!\n" if $volname eq "vm-".$vm_id."-data1";
    die "ERROR: volume: $volname exist on target $host. Remove it before creating vm!\n" if $volname eq "vm-".$vm_id."-data2";
}


print "INFO: create BOOT volume $boot GiB on $host\n";
$xml = <<_VOL_
<volume type='block'>
  <name>vm-$vm_id-boot</name>
  <capacity unit='GiB'>$boot</capacity>
  <allocation unit='GiB'>$boot</allocation>
  <physical unit='bytes'>$boot</physical>
</volume>
_VOL_
;
my $boot_volume;
eval {
	$boot_volume = $ssd_pool->create_volume($xml);
	$disks_section .= " --disk /dev/". $ssd_pool->get_name() ."/vm-${vm_id}-boot,device=disk,bus=virtio ";
	$disks_section .= " --disk $cidatadir/vm-$vm_id-cidata.iso,device=cdrom ";
};
if ($@) {
  die "Unable create BOOT volume on $host" . $@->message . "\n";
}

if ( ${ssd} ) {
  print "INFO: create DATA1 volume $ssd GiB on $host\n";
  $xml = <<_VOL_
<volume type='block'>
  <name>vm-$vm_id-data1</name>
  <capacity unit='GiB'>$ssd</capacity>
  <allocation unit='GiB'>$ssd</allocation>
  <physical unit='bytes'>$ssd</physical>
</volume>
_VOL_
;
  eval {
	$ssd_pool->create_volume($xml);
	$disks_section .= " --disk /dev/". $ssd_pool->get_name() ."/vm-${vm_id}-data1,device=disk,bus=virtio ";
  };
  if ($@) {
    die "Unable create DATA1 volume on $host" . $@->message . "\n";
  }
}
if ( ${hdd} ) {
  print "INFO: create DATA2 volume $hdd GiB on $host\n";
  $xml = <<_VOL_
<volume type='block'>
  <name>vm-$vm_id-data2</name>
  <capacity unit='GiB'>$hdd</capacity>
  <allocation unit='GiB'>$hdd</allocation>
  <physical unit='bytes'>$hdd</physical>
</volume>
_VOL_
;
  eval {
	$hdd_pool->create_volume($xml);
	$disks_section .= " --disk /dev/". $hdd_pool->get_name() ."/vm-${vm_id}-data2,device=disk,bus=virtio ";
  };
  if ($@) {
    die "Unable create DATA2 volume on $host" . $@->message . "\n";
  }
}

#print $disks_section;
#print $networks_section;

my $cidatafile = "$tempdir/vm-${vm_id}-cidata.iso";
my $cidata_size = -s $cidatafile;

print "INFO: transfering cidata to all hypervisor\n";
foreach my $target ( get_all_hv() ) {
  my $c;
  print "    ", $target, "\n";

  my $uri="qemu+ssh://". &get_default('become_user') . "\@$target/system";
  eval { $c = Sys::Virt->new(uri =>$uri ); };
  if ($@) {
    die "Unable to open connection to $target" . $@->message . "\n";
  }
  my $st = $c->new_stream();

  my $pool;
  my $vol;
  eval { $pool = $c->get_storage_pool_by_name('cidata'); };
  if ($@) {
    die "Unable to find cidata pool on $target" . $@->message . "\n";
  }

  eval { $vol = $c->get_storage_volume_by_path("$cidatadir/vm-$vm_id-cidata.iso"); };
  if ( not ($@))  {
    $vol->delete( Sys::Virt::StorageVol::DELETE_NORMAL );
  }


  $xml = <<_VOL_
<volume type='file'>
  <name>vm-$vm_id-cidata.iso</name>
  <capacity unit='bytes'>$cidata_size</capacity>
  <allocation unit='bytes'>$cidata_size</allocation>
  <physical unit='bytes'>$cidata_size</physical>
  <target>
    <path>$cidatadir/vm-$vm_id-cidata.iso</path>
    <format type='iso'/>
    <permissions>
      <mode>0644</mode>
      <owner>0</owner>
      <group>64055</group>
    </permissions>
  </target>
</volume>
_VOL_
;
  eval {
	$pool->create_volume($xml);
  };
  $vol = $c->get_storage_volume_by_path("$cidatadir/vm-$vm_id-cidata.iso");
  open FILE, "<$cidatafile" or die "cannot open $cidatafile: $!";

  sub cidata_read {
        my $st = $_[0];
        my $nbytes = $_[2];
        return sysread FILE, $_[1], $nbytes;
  };

  eval {
    $vol->upload($st, 0, 0);
    $st->send_all(\&cidata_read);
    $st->finish();
  };

  if ($@) {
    close FILE;
    die $@;
  }
  close FILE or die "cannot save $cidatafile $!";
}
print "INFO: copy boot image $image to ".$boot_volume->get_name()." on $host\n";

#
# copy image to volume
# быстро заливаем image на созданный виртуальный диск
#`ssh  $SSHOPTIONS $become_user@$host "sudo dd if=$image of=/dev/$pool/vm-${vm_id}-boot bs=512K 2>/dev/null"`
#
my $CMD="ssh ".get_default('sshoptions')." $become_user\@$host ";
#$CMD .='"sudo dd status=progress bs=512K if='. $image . ' of=/dev/'. $ssd_pool->get_name() .'/vm-'.${vm_id}.'-boot 2>/dev/null"';
$CMD .='"sudo dd status=progress bs=512K if='. $image . ' of=/dev/'. $ssd_pool->get_name() .'/vm-'.${vm_id}.'-boot"';
#print $CMD;
`$CMD`;


print "INFO: create vm on $host\n"; 
$CMD = <<_VIRT_INSTALL_
virt-install  --connect $libvirt_uri \\
  --name vm-$vm_id \\
  --metadata title='vm-$vm_id\($vm_name\)' \\
  --vcpus \"${vm_vcpu}\" \\
  --memory \"${vm_ram}\" \\
  --os-variant=\"$os_variant\" \\
  --virt-type $virt_type \\
 $networks_section \\
 $disks_section \\
  --console pty,target_type=serial \\
  --import \\
  --noreboot \\
  --noautoconsole \\
 2>&1 >/dev/null 
_VIRT_INSTALL_
;

#print $CMD;

system ( $CMD) ;

# копируем gold_image на все серверы группировки, проверяя что их действительно нужно копировать
die "ERROR: can't copy vm config to hypervisors...\n" if not -f "$tempdir/vm-${vm_id}-config.yml";
print "INFO: copy vm-config to hypervisors...\n"; 
foreach my $target ( get_all_hv() ) {
	my $ruser = get_default ('rsync_user');
	my $rscr = get_default ('rsync_scr');
	my $module = get_default ('rsync_module');
	my $rdst = get_default('vm_configs') =~ s#$rootdir/##r;
	print "    ", $target, " ";

	#print "rsync -u --info=name1 --password-file=$rscr $tempdir/vm-${vm_id}-config.yml $ruser\@${target}::${module}/$rdst";
	system( "rsync -u --info=name1 --password-file=$rscr $tempdir/vm-${vm_id}-config.yml $ruser\@${target}::${module}/$rdst");
}

