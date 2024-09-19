#!/usr/bin/perl
use v5.28;

# apt install \
# libyaml-tiny-perl \
# libsys-virt-perl \
# liblinux-lvm-perl \
# libnet-cidr-perl \
# libnet-netmask-perl \
# libnetaddr-ip-perl \
# libxml-simple-perl \
# libgetopt-long-descriptive-perl \
# libnet-ip-perl

use strict;
use warnings;
use Sys::Virt;
use Sys::Virt::StoragePool;
use XML::Simple;
use YAML::Tiny;
use Getopt::Std;
use File::Basename;

use lib '/var/123-cloud/scripts';
use lib '/var/123-cloud/scripts/PL';
use utils qw(get_default get_all_hv);

my $proto = 'qemu+ssh';
my $schema = 'system';
my $username = get_default('become_user');
my %domstate = (
  Sys::Virt::Domain::STATE_NOSTATE,     "no state",
  Sys::Virt::Domain::STATE_RUNNING,     "running",
  Sys::Virt::Domain::STATE_BLOCKED,     "blocked",
  Sys::Virt::Domain::STATE_PAUSED,      "paused",
  Sys::Virt::Domain::STATE_SHUTDOWN,    "shutdown",
  Sys::Virt::Domain::STATE_SHUTOFF,     "inactive",
  Sys::Virt::Domain::STATE_CRASHED,     "crashed",
  Sys::Virt::Domain::STATE_PMSUSPENDED, "suspend" 
);

my $parser = new XML::Simple;

my %options=();
getopts("hedi:t:", \%options);

my $prog = basename($0);
die "usage: $prog [-h]|[-e][-d][ -i vm_id | -t target_hv ]\n -e no ethernet, \n -d no disks\n"  if defined $options{h};

print "Use target_hv: $options{t}\n"  if defined $options{t};
print "Find vm_id: $options{i}\n"  if defined $options{i};

my $yaml = YAML::Tiny->read( '/var/123-cloud/etc/123-config');
my @hvnames =  sort (keys ( %{ $yaml->[0]->{hypervisors} } ));

foreach ( @hvnames ) {
    my $con;
    my $server = $_;

    if ( defined $options{t} ) {
    	next if $server !~ /$options{t}$/ 
    }

    my $addr = $proto."://".$username."@".$server."/".$schema;

    eval { $con = Sys::Virt->new(uri => $addr, readonly => 0); };
    if ($@) {
      print STDERR "Unable to open connection to $addr" . $@->message . "\n";
    }

    my $nodeinfo = $con->get_node_info();
    my $nodecpus = $nodeinfo->{cpus};
    my $nodemem = int ( $nodeinfo->{memory}/1024/1024 );

    printf "--------- %-10s     total: CPU(s): %s RAM: %s ----------\n", $server, $nodecpus, $nodemem;

    foreach my $dom (sort { $a->get_id <=> $b->get_id } $con->list_all_domains) {
    
        my $name = $dom->get_name;
        my $info = $dom->get_info;
        my $parsedxml =  $parser->XMLin($dom->get_xml_description);
        my $title = $parsedxml->{'title'} || "";
        my $vcpus = $info->{'nrVirtCpu'};
        my $vram = $info->{'memory'} / 1024 /1024;
        my $state =  $domstate{ $info->{'state'} };

        if ( defined $options{i} ) {
    	   next if $name !~ /$options{i}$/ 
        }
        my $hostname = ( $state =~ /run/ )?  $dom->get_hostname() : ($title =~ /$name\((.*)\)/, $1 || "");
        printf "%-12s CPU: %-3d RAM: %-6d State: %-8s Name: %-30s\n", $name, $vcpus, $vram, $state, $hostname;
	if ( not defined ( $options{e} )) {
          if ( $state =~ /running/ ) {
  	      $nodemem -= $vram;
	      $nodecpus -= $vcpus;
  
              my @nics = $dom->get_interface_addresses(Sys::Virt::Domain::INTERFACE_ADDRESSES_SRC_AGENT);

              foreach my $nic (@nics) {
                if ( $nic->{name} =~ /^eth/ ) {
                    printf "%76s %5s ( %12s )\n", " ", $nic->{name}, $nic->{hwaddr};

                    foreach my $addr (@{$nic->{addrs}}) {

                        printf "%78s IP: %s\n", " ", $addr->{addr};
                    }
                 }
              }
          }
        }
	if ( not defined ( $options{d} )) {
          my @disk_devices = $parsedxml->{'devices'}->{'disk'};

          foreach my $disk (@disk_devices) {
            my $num_items = @$disk;
            for (my $i =0; $i <$num_items; $i++) {
              if ( $disk->[$i]->{'type'} =~ /block/ ) {
                    my $disk_target = $disk->[$i]->{'target'}->{'dev'};
                    my $disk_source = $disk->[$i]->{'source'}->{'dev'};
                    my $disk_info = $dom->get_block_info( $disk_source );
                    my $disk_capacity = $disk_info->{'capacity'}/1024/1024/1024;

                    printf "%77s%4s: %4s Gib %s\n", ' ', $disk_target, $disk_capacity, $disk_source;
                }
             }
          }
       }
    }
    printf "--------- %-10s available: CPU(s): %s RAM: %s ----------\n", $server, $nodecpus, $nodemem;
}
