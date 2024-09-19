#!/usr/bin/env perl
#
package utils;

use parent 'Exporter';  # inherit all of Exporter's methods
our @EXPORT_OK = qw(get_default get_user_name get_user_password get_domain get_ssh_authorized_keys get_default get_target get_vlan_for_network get_networks_for_vlan get_default_vlan get_uniq_id get_all_hv);  # symbols to export on request

use YAML::Tiny;
use Net::IP;
use Net::CIDR;
use NetAddr::IP;
use Data::Dumper;
#
my @configs;
my $global_config;
$global_config=YAML::Tiny->read('/var/123-cloud/etc/123-config');

foreach ( my @files = glob ( get_default('vm_configs').'/vm-*-config.yml' ) ) {
	chomp;
	push @configs, (YAML::Tiny->read($_));
}


# vlan->[ #0 vlan, #1 portgroup, #2 network, #3 mask, #4 bits, #5 gateway] 
# print %global_networks{$vlan}->[0], "\n";
my %global_networks; 
my @global_reservations;
my $default_vlan = 110;

{ # block of load config
	my @netdefs;
	foreach ($global_config->[0]->{networks}) {
		@netdefs = @{ $_ };	
		foreach ( @netdefs ) {
                        #print $_->{vlan}, "\n", $_->{portgroup}, "\n", $_->{network}, "\n", $_->{mask}, "\n", $_->{bits}, "\n";
			my @params = ($_->{vlan}, $_->{portgroup}, $_->{network}, $_->{mask}, $_->{bits}, $_->{gateway});
			$default_vlan = $_->{vlan} if defined $_->{default};
			$global_networks{$_->{vlan}}=\@params;
			push @global_reservations, @{$_->{reservations}};

		}
	}
}

sub bold  { print "\e[1m", @_, "\e[0m" ; }
sub red   { print "\e[31m", @_, "\e[0m" ; }
sub green { print "\e[32m", @_, "\e[0m" ; }
sub yellow { print "\e[33m", @_, "\e[0m" ; }
sub ok { green   "@_"  || "OK"  ;}


#die() { red "ERR: $@" >&2 ; exit 2 ; }
#silent() { "$@" > /dev/null 2>&1 ; }
#output() { echo -e "- $@" ; }
#outputn() { echo -en "- $@ ... " ; }

#pushd() { command pushd "$@" >/dev/null ; }
#popd() { command popd "$@" >/dev/null ; }

sub get_user_name {
	return $global_config->[0]->{defaults}->{user};
}
sub get_user_password {
	return $global_config->[0]->{defaults}->{password};
}
sub get_domain {
	return $global_config->[0]->{defaults}->{domain};
}
sub get_ssh_authorized_keys {
	my $keys;
	foreach ( @{$global_config->[0]->{defaults}->{ssh_authorized_keys}} ){
	$keys .= "  - ".$_."\n";
	}
	return $keys;
}


sub get_default {
	my $param = shift || return undef;
	my $rootdir =  $global_config->[0]->{defaults}->{rootdir};

	return $global_config->[0]->{defaults}->{$param} =~ s/_ROOTDIR_/$rootdir/r;
}

#print $global_config->[0]->{defaults}->{search}, "\n";
#print ( join "nameserver: ", $global_config->[0]->{defaults}->{nameservers}), "\n";
#print $global_config->[0]->{defaults}->{ssh_authorized_keys}, "\n";
#
sub get_vm_name_by_id {
	my $vm_id = shift || die "No valid vm id supplied\n";
	return get_vm_param_by_id( $vm_id, 'name');
}
sub get_vm_target_by_id {
	my $vm_id = shift || die "No valid vm id supplied\n";
	return get_target( get_vm_param_by_id( $vm_id, 'target'));
}

sub get_vm_param_by_id {
	my $vm_id = shift || die "No valid vm id supplied\n";
	my $param = shift || die "No valid param supplied\n";

	foreach my $conf (@configs) {
		my $conf_id = $conf->[0]->{id};
		return $conf->[0]->{$param} if $conf_id == $vm_id;
	}
	die "No valid vm id=$vm_id supplied\n";
}

sub get_all_hv {
	my @targets;
	foreach ( keys ( %{ $global_config->[0]->{hypervisors} } )) {
		push @targets, ($global_config->[0]->{hypervisors}->{$_});
	}
	return @targets;
}

sub get_target_num {
	my $target = shift || `hostname`;
	chomp $target;

	my ( $id ) = $target  =~ m#(\d+)$#;
	return $id;
}

sub get_target {
	my $target = shift || `hostname`;
	chomp $target;

	my ( $id ) = $target  =~ m#(\d+)$#;

	foreach ( keys ( %{ $global_config->[0]->{hypervisors} } )) {
		my ( $t ) = $_  =~ m#(\d+)$#;
		return  $global_config->[0]->{hypervisors}->{$_} if $t eq $id;
	}
	die "ERROR: wrong target: $target\n";
}

sub portgroup_check {
	my $vlan = shift;
	my $vlan_used = 0;

	my $ref = %global_networks{$vlan};

	return undef if not defined $ref;
	return %global_networks{$vlan}->[1];
}

sub get_vlan_for_network {
	my ( $network ) = split '/', @_[0];

	foreach my $vlan ( keys ( %global_networks )) {
		return $vlan if ( %global_networks{$vlan}->[2] =~ /^$network$/ );
	}
	return 0;
}

sub get_networks_for_vlan {
	my $vlan = @_[0];

	my $ref = %global_networks{$vlan};

	return undef if not defined $ref;
	return %global_networks{$vlan}->[2];
}

sub get_default_vlan {
	return $default_vlan;
}

sub parse_address_string { # <vm_ip0>[/<mask_bits0>[:vm_mac0]]]
	my $vlan = get_default_vlan();

	my $param = shift || %global_networks{$vlan}->[2]."/".$global_networks{$valn}->[4];
	$param .= "/:";

	my $a, $b, $c, $d, $mask, $mac;
	my $address;

	( $a, $b, $c, $d, $mask, $mac ) = $param =~ m#(\d+)\.(\d+)\.(\d+)\.(\d+)\/([0-9\.]*):?([a-fA-F0-9:]*)\/?:?#;
	# mask - may be real mask or masklen in bits
	$mask =  %global_networks{$vlan}->[4] if ( not $mask  ); # use bits value from defaults if not set
	$address = $a.".".$b.".".$c.".".$d;

	$mac = gen_mac() if not $mac;

	die "ERROR: MAC $mac used in system" if mac_check( $mac );

	my $ip = NetAddr::IP->new ( $address , $mask );
	# check network validity
	$vlan = get_vlan_for_network( $ip->network() );
	die "ERROR: network $ip not configured for VM use" if not $vlan;

	# produce new address if only network are passed
	if ( $ip->network() =~ m/$address/ ) {
		# need to generate new ip
		#"$me->contains($other)";
		for ( my $i=1;  ;++$i ) {
			$_IP =  NetAddr::IP->new($ip) + $i;
			$address = $_IP;
			# print $i, " ", $address," " , $ip->broadcast(), "\n";
			die "IPs in network: $ip->network() finished... exiting..." if $ip->broadcast() == $_IP;
			last if not ipaddr_check($_IP); 
		} 
	} else {
	# check supplyed ip address
		die "ERROR: IP $address is already used\n" if ipaddr_check( $address );
		die "ERROR: IP $address is broadcast address\n" if $ip->broadcast() == $address."/".$ip->masklen;
		die "ERROR: IP $address is network address\n" if $ip->network() == $address."/".$ip->masklen;
	}
	# retuen what we know about ip address
	( $address ) = split '/', $address;
	return ( $vlan, $address, $ip->mask(), $ip->masklen(), $mac, %global_networks{$vlan}->[1], %global_networks{$vlan}->[5], $d, $c, $b, $a );

}


# return 0 if addr not exist in configs 
# return 1 if addr exist in configs 
sub ipaddr_check {
	my $mask;
	my $ip_used = 0;
	my $cidr = shift . "/";

	( $addr , $mask ) = split '/', $cidr;

	$mask = shift if scalar @_;
	foreach ( @global_reservations ) {
	    $ip_used = ( $_ =~ /^$addr$/);
	    return 1 if $ip_used;
	}

	foreach my $conf (@configs) {
		foreach my $conf_net ( @{$conf->[0]->{networks}}) {
		    my ( $conf_cidr , $conf_mask ) = split '/', $conf_net->{cidr};
	    	    $ip_used = ( $addr =~ /^$conf_cidr$/) if defined $conf_cidr;

		    #if ( defined $conf_cidr ) {
		    #	$ip_used = 1 if $addr =~ m#$conf_cidr#;
		    #}
		    return 1 if $ip_used;
		}
	}
	return 0; 
}

sub vmid_check {
	my $vmid_ = shift ;
	foreach my $conf_ (@configs) {
		    return 1 if $vmid_ == $conf_->[0]->{id}; 
	}
	return 0; 
}

sub get_uniq_id {
	my $vmid = ( defined @configs[0] )? @configs[0]->[0]->{id} : "100";
	my $count = scalar ( @configs );

	for ( my $i=0; $i < $count ; ++$i) {
		++$vmid;
		return $vmid if ( not defined ( @configs[$i+1] ) );
		return $vmid if ( $vmid !=  @configs[$i+1]->[0]->{id} );
	}
	return $vmid;
}

sub mac_check {
	my $mac = shift ;
	my $mac_used = 0;

	foreach my $conf (@configs) {
		foreach my $conf_net ( @{$conf->[0]->{networks}}) {
			my $conf_mac = $conf_net->{mac};
		    $mac_used = ( $mac =~ /^$conf_mac$/) if defined $conf_mac;
		    return 1 if $mac_used;
		}
	}
	return 0; 
}

sub gen_mac {
   my $start=$_[0] || "22:2f:e5"; #00:9f:6d
   my $m1,  $m2,  $m3;

   for( my $i=100; $i; --$i) {
      $m1=`cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=2 count=1 2>/dev/null`;
      $m2=`cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=2 count=1 2>/dev/null`;
      $m3=`cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=2 count=1 2>/dev/null`;
      $mac = $start.":$m1:$m2:$m3";
      return $mac if not mac_check ($mac);
     } 
  die "can't find unique mac address";
}

sub mkpasswd_hash {
  my $pass; my $salt; my $hash;

  $pass = $_[0] || "";
  $salt = `cat /dev/urandom | tr -dc '[:alnum:]' | dd bs=4 count=2 2>/dev/null`;
  $hash = `openssl passwd -6 -salt ${salt} $pass`;
  chomp $hash;
  return $hash;
}

sub gen_machineid {
  my $ret;
  $ret = `cat /dev/urandom | tr -dc '[:xdigit:]' | tr '[:upper:]' '[:lower:]' | dd bs=4 count=10 2>/dev/null`;
  return $ret;
}


sub fill_env {

print "export workdir=/tmp/vm-create.$$", "\n";
# common dir names
print "export IMAGES=images\n";
print "export CIDATA=cidata\n";
print "export AUTH=auth\n";
print "export TEMPLATES=templates\n";
print "export VM_CONFIGS=vm-configs\n";
print "export SCRIPTS=scripts\n";

# dirs
print "export INSTALLDIR=".get_default('rootdir')."\n";
print "export SCRIPTSDIR=".get_default('scripts')."\n";
print "export VMCONFIGDIR=".get_default('vm_configs')."\n";
print "export TEMPLATESDIR=".get_default('templates')."\n";
print "export AUTHDIR=".get_default('auth')."\n";
print "export CIDATADIR=".get_default('cidata')."\n";
print "export IMAGESDIR=".get_default('images')."\n";
print "export TEMPDIR=".get_default('tmp')."\n";

print "export DEFAULTIMAGE=".get_default('defaultimage')."\n";
print "export SSHOPTIONS='".get_default('sshoptions')."'"."\n";
print "export BECOME_USER=".get_default('become_user')."\n";
print "export RSYNC_USER=".get_default('rsync_user')."\n";
print "export CLOUD_USER=".get_default('rsync_user')."\n";
print "export RSYNC_SCR=".get_default('rsync_scr')."\n";
print "export RSYNC_MODULE=".get_default('rsync_module')."\n";
print "export vm_domain=".get_default('domain')."\n";
print "export vm_password=".get_default('password')."\n";

print 'export DEFAULTCFG=$TEMPLATESDIR/vm-default-config\n';

print "export DEFAULTVLAN=".$global_networks{$default_vlan}->[1]."\n";
print "export DEFAULTCIDR=".$global_networks{$default_vlan}->[2]."/".$global_networks{$default_vlan}->[4]."\n";
print "export vm_mask=".$global_networks{$default_vlan}->[3]."\n";
print "export vm_ns1=".$global_config->[0]->{defaults}->{nameservers}->[0]."\n";
print "export vm_ns2=".$global_config->[0]->{defaults}->{nameservers}->[1]."\n";
print "export SERVERS='". join ( " ", sort keys ( %{ $global_config->[0]->{hypervisors} } )) ."'\n";

print "export SERVER_PREFIX=".get_default('serverprefix'). "\n";
print "export RSYNC_PREFIX=".get_default('serverprefix'). "\n";
}
1;
