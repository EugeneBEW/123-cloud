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
use utils qw(get_default get_all_hv);

STDOUT->autoflush(1);

my %options=();
getopts("hn:i:", \%options);

my $prog = basename($0);
my $usage=<<_USAGE_;

  usage: $prog [-h]| [-n <vm_name>] -i <vm_id> 

  Run VM with id 

_USAGE_

die $usage if defined $options{h};

die "ERROR: VM_ID must be exist\n" if ( not defined $options{i} );
my $vm_id = $options{i};

utils::vmid_check($vm_id) || die "ERROR: VM_ID $vm_id must be exist\n";

my $target =  utils::get_vm_target_by_id($vm_id);
my $vm_name="vm-$vm_id";

my $proto = 'qemu+ssh';
my $schema = 'system';
my $username = get_default('become_user');

my $addr = $proto."://".$username."@".$target."/".$schema;

my $conn;
eval { $conn = Sys::Virt->new(uri => $addr, readonly => 0); };
if ($@) {
      print STDERR "Unable to open connection to $addr" . $@->message . "\n";
}

my $dom;
eval { $dom = $conn->get_domain_by_name($vm_name); };
if ($@) {
      print STDERR "Unable to get domain by name $vm_name" . $@->message . "\n";
}

if ( $dom->is_active()) {
	utils::yellow( "Warning: vm-$vm_id already running...\n" );
} else {
	utils::green( "INFO: vm-$vm_id starting...\n" );
	$dom->create();
        sleep(2);
	utils::yellow("Warning: vm-$vm_id starting...")  if not $dom->is_active();
}




