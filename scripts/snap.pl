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
use IO::Handle;

use Scalar::Util qw(looks_like_number);


use lib '/var/123-cloud/scripts';
use lib '/var/123-cloud/scripts/PL';
use utils qw(get_default get_all_hv);

my %options=();
getopts("hn:i:", \%options);

my $prog = basename($0);
my $usage=<<_USAGE_;

  usage: $prog [-h]| [-n <vm_name>] -i <vm_id>

  Stop VM with id and name (optional)

_USAGE_

die $usage if defined $options{h};

die "ERROR: VM_ID must be exist\n" if ( not defined $options{i} );
my $vm_id = $options{i};

utils::vmid_check($vm_id) || die "ERROR: VM_ID $vm_id must be exist in configs\n";

my $host =  utils::get_vm_target_by_id($vm_id);
my $vm_name="vm-$vm_id";

my $proto = 'qemu+ssh';
my $schema = 'system';
my $vmconfigdir = get_default('vm_configs');
my $cidatadir = get_default('cidata');
my $become_user=get_default('become_user');


my $uri = $proto."://".$become_user."@".$host."/".$schema;

my $conn;
eval { $conn = Sys::Virt->new(uri => $uri, readonly => 0); };
if ($@) {
      die "Unable to open connection to $uri" . $@->message . "\n";
}

my $dom;
eval { $dom = $conn->get_domain_by_name($vm_name); };
if ($@) {
      die "Unable to get domain by name $vm_name" . $@->message . "\n";
} 

my @pools;
my $ssd_pool;
my $hdd_pool;
my $ssd_prefix = get_default('ssd_prefix');
my $hdd_prefix = get_default('hdd_prefix');

eval { @pools = $conn->list_all_storage_pools(); };
if ($@) {
  die "Unable to get list of pools on $host" . $@->message . "\n";
}

print "INFO: find SSD and HDD pools on $host\n";
eval {
    foreach my $pool ( @pools ) {
            my $name = $pool->get_name();

            $ssd_pool = $pool if $name =~ m/$ssd_prefix/;
            $hdd_pool = $pool if $name =~ m/$hdd_prefix/;
    }
};
if ($@) {
  die "Unable to find SSD or HDD pool on $host" . $@->message . "\n";
}

my @volumes;
eval {
    @volumes = ( $ssd_pool->list_all_volumes() , $hdd_pool->list_all_volumes());
};
if ($@) {
  die "ERROR: Unable to list pools on $host" . $@->message . "\n";
}
print "INFO: snapshoting vm-$vm_id-{boot,data1,data2} on $host\n";
my @volpath;

foreach ( @volumes ) {
    my $volname = $_->get_name();

    push @volpath , $_->get_path() if $volname eq "vm-".$vm_id."-boot";
    push @volpath, $_->get_path() if $volname eq "vm-".$vm_id."-data1";
    push @volpath, $_->get_path() if $volname eq "vm-".$vm_id."-data2";
}

print "INFO: do sync on guest block devices:". join " " ,  @volumes ."on $host\n";
my $CMD = <<_GUEST_AGENT_
#!/usr/bin/env bash
#set -x
LANG=C virsh --connect $uri domstate vm-$vm_id | grep 'running' >/dev/null && {

  pid=\$(virsh --connect $uri qemu-agent-command vm-$vm_id --cmd '{"execute": "guest-exec", "arguments": { "path": "/usr/bin/sync", "capture-output": true }}' | jq '.return.pid')

  #echo \$pid
  i=0
  e=0
  #echo "syncing runing guest. wait"
  [[ -n \$pid ]] && until (( i >= 300 || e == 1 )) ; do 
    {
    if (( i <= 300 )) ; then
	    sleep 1 && let ++i #&& echo -n "."
    else
	#echo; echo "Cant' sync guests filesystem"
        e=1
    fi
  
    set \$(virsh --connect $uri qemu-agent-command vm-$vm_id --cmd "{\\"execute\\": \\"guest-exec-status\\", \\"arguments\\": { \\"pid\\": \$pid }}" | jq '.return|.exited,.exitcode')
  
    [[ "\$1" == 'true' && \$2 == '0'  ]] && break;
    }
  done
  [[ \$e == 1 ]] &&  echo -n non
}
_GUEST_AGENT_
;
my $ret=`$CMD`;

my $suffix=`date '+%Y%m%d-%H%M%S'`;
chomp($suffix);

# TO DO [[ $consistent_flag == 'non' ]] do suspend if available in comand options 
foreach my $vol ( @volpath ) {
    my ( $pool, $name ) = $vol =~ m#\/dev\/([_\-A-Za-z0-9]+)\/([_\-A-Za-z0-9]+)#;

    die "ERROR: $pool -> $name: wrong values\n" if ( not $pool ) or (not $name ); 

    print "INFO: make temporary snapshot pre-snap-$name-$suffix on $host\n";

    $CMD="ssh $become_user\@$host sudo lvcreate --snapshot --size 10G --name pre-snap-$name-$suffix $vol";
    `$CMD`;
}

foreach my $vol ( @volpath ) {
    my ( $pool, $name ) = $vol =~ m#\/dev\/([_\-A-Za-z0-9]+)\/([_\-A-Za-z0-9]+)#;

    print "INFO: copy temporary snapshot to persistent snap-$name-$suffix on $host\n";
    my $vol_size = `ssh $become_user\@$host sudo lvs -o size --units 'g' --reportformat json $pool/$name | jq .report[0].lv[0].lv_size`;
    chomp($vol_size);

    $CMD="";
    $CMD .= "ssh  $become_user\@$host 'sudo lvcreate -y --size $vol_size --name snap-$name-$suffix $pool && "; 
    $CMD .= "sudo dd status=progress bs=1024M if=/dev/$pool/pre-snap-$name-$suffix of=/dev/$pool/snap-$name-$suffix && ";
    $CMD .= "sudo lvremove -y $pool/pre-snap-$name-$suffix'";
    `$CMD`;    
}

