# 123-cloud

This is a set of scripts and it’s configuration files which simplify management tasks for small private cloud upon native virtualization in linux based on libvirt/kvm and lvm volumes for vm’s disks.
The goal of scripts is:
1.	Assign unique over all hypervisors vm name aka numeric id
2.	Assign unique IP addresses for vm ethers over all hypervisors 
3.	Assign unique MAC addresses for vm interfaces over all hypervisors
4.	Build cloud-init config as iso image for configuring vm as noCloud datasource
## Scripts can:
Create vm from predefined raw image(s) with one boot disk, and two data disks and no more than 4 ethers on desired hypervisor
Start vm by id (no matter in which hypervisor vm located)
Stop vm by id  (no matter in which hypervisor vm located)
Migrate vm in two ways – if vm running – try to make live migration, if not running – simple transfer vm

## configuration
Install/copy  scripts into /var/123-cloud 
Run scripts/123-install.sh for installation of required packaches and libs

Fill etc/123-config yaml file with your's configuration

## requirements
1. hypervisor networking based on open-vswitch - the example of network configuration provided in network/ directory
2. use identical names for hypervisor exept it's numer, like hv1...## -  fill 123-config
3. create ssh key and make nopassword ssh access beatween all hypervisors - fill 123-config
4. make two lvm pools for data disks of VM use names like  {SSD,HDD}_POOL##:
   when vm are created it's disks  are SSD_POOL#/vm-ID-boot SSD_POOL#/vm-ID-data1 HDD_POOL#/vm-ID-data2
   other disks may be added manualy in virsh if desired
5. define networking and disk pools in virsh
6. copy your's  gold imagees to images/ dir and add a reference to it on 123-config

 ## addendum
 There are a lot of options in 123-config 
   - you may exlude some ip addresses from assign mechanis
   - for hypervisors try to use netwoking with JUMBO frames
