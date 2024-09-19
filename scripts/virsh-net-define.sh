#!/bin/bash

br_uid=$(ovs-vsctl show | head -1)


cat <<EOF > ./ovs-network.xml
<network>
<name>ovs-network</name>
  <uuid>$br_uid</uuid>
  <forward mode='bridge'/>
  <bridge name='backplane1'/>
  <virtualport type='openvswitch'/>
  <portgroup name='vlan-100'>
    <vlan>
      <tag id='100'/>
    </vlan>
  </portgroup>
  <portgroup name='vlan-110'>
    <vlan>
      <tag id='110'/>
    </vlan>
  </portgroup>
<!--
  <portgroup name='trunkPortGroup'>
    <vlan trunk='yes'>
      <tag id='30'/>
      <tag id='1030'/>
    </vlan>
  </portgroup>
-->
</network>
EOF

virsh net-define ./ovs-network.xml
virsh net-start ovs-network
virsh net-autostart ovs-network
