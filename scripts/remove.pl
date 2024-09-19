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

STDOUT->autoflush(1);

#'print utils::get_vm_target_by_id(101)." ".utils::get_vm_name_by_id(101);')

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


my $addr = $proto."://".$become_user."@".$host."/".$schema;

my $conn;
eval { $conn = Sys::Virt->new(uri => $addr, readonly => 0); };
if ($@) {
      print STDERR "Unable to open connection to $addr" . $@->message . "\n";
}

my $dom;
eval { $dom = $conn->get_domain_by_name($vm_name); };
if ($@) {
      print STDERR "Unable to get domain by name $vm_name" . $@->message . "\n";
      utils::red ( "WARNING: try remove artefacts for unexisting domain (yaml config exist, vm undefined in libvirt)\n");
} else {
  $dom->destroy() if $dom->is_active();
  $dom->undefine();
} 
# ищем подходящий LVM вольюм на быстром разделе у нас они названы SSD или DATA1 - кто именно не важно
#
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
  die "ERROR: Unable to start pools on $host" . $@->message . "\n";
}
print "INFO: delete vm-$vm_id-{boot,data1,data2} from $host\n";
foreach ( @volumes ) {
    my $volname = $_->get_name();

  eval {
    $_->delete() if $volname eq "vm-".$vm_id."-boot";
    $_->delete() if $volname eq "vm-".$vm_id."-data1";
    $_->delete() if $volname eq "vm-".$vm_id."-data2";
  };
  if ($@) {
    die "ERROR: Unable to delete $volname on $host" . $@->message . "\n";
  }
}

print "INFO: delete cidata/vm-$vm_id-cidata.iso from all hypervisor\n";
foreach my $target ( get_all_hv() ) {
  my $c;
  print "    ", $target, "\n";

  my $uri="qemu+ssh://". &get_default('become_user') . "\@$target/system";
  eval { $c = Sys::Virt->new(uri =>$uri ); };
  if ($@) {
    die "Unable to open connection to $target" . $@->message . "\n";
  }
  my $pool;
  my $vol;
  eval { $pool = $c->get_storage_pool_by_name('cidata'); };
  if ($@) {
     utils::yellow ( "Unable to find cidata pool on $target" . $@->message . "\n" );
  }

  eval { $vol = $c->get_storage_volume_by_path("$cidatadir/vm-$vm_id-cidata.iso"); };
  if ( not ($@))  {
    $vol->delete( Sys::Virt::StorageVol::DELETE_NORMAL );
  }
}

print "INFO: delete vm-configs/vm-$vm_id-config.yml from all hypervisor\n";
foreach my $target ( get_all_hv() ) {
     my $CMD="ssh ".get_default('sshoptions')." $become_user\@$target ";
     $CMD .="sudo rm -f ".get_default('vm_configs')."/vm-${vm_id}-config.yml"; 
     `$CMD`;
}

