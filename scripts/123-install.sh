#!/bin/bash

# install packaches
#
prog=$(basename $0)

apt update && yes | apt install \
 openvswitch-switch netcat rsync htop \
 uuid-runtime uuid kpartx multipath-tools \
 xml2 jq curl \
 xauth virt-manager virt-viewer virtinst

yes | apt install libyaml-tiny-perl libsys-virt-perl liblinux-lvm-perl \
	libnet-cidr-perl libnet-netmask-perl libnetaddr-ip-perl \
	libxml-simple-perl libnet-ip-perl libgetopt-long-descriptive-perl



useradd  --no-create-home --system 123-cloud
usermod -aG astra-admin 123-cloud
usermod -aG libvirt,libvirt-qemu,libvirt-admin,libvirt-admvm,libvirt-dev,kvm 123-cloud
usermod -aG libvirt,libvirt-qemu,libvirt-admin,libvirt-admvm,libvirt-dev,kvm mailcloud
usermod -aG 123-cloud libvirt-qemu

pdpl-user -i 63 123-cloud

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}


[[ -f /tmp/123-cloud.update.tar ]] && tar xvpf /tmp/123-cloud.update.tar -C /var/ 

#[[ -f $SCRIPTSDIR/123-defs.sh ]] && source $SCRIPTSDIR/123-defs.sh
[[ -f $SCRIPTDIR/utils.pm ]] && eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh

export LANG=C

mkdir -p $INSTALLDIR
mkdir -p $SCRIPTSDIR
mkdir -p $VMCONFIGDIR
mkdir -p $TEMPLATESDIR
mkdir -p $AUTHDIR
mkdir -p $TEMPDIR
mkdir -p $CIDATADIR
mkdir -p $IMAGESDIR
mkdir -p $INSTALLDIR/etc

chown -R $CLOUD_USER:$CLOUD_USER $INSTALLDIR

find $INSTALLDIR -type d -exec chmod 775 {} \;
find $INSTALLDIR -type f -exec chmod 664 {} \;
find $SCRIPTSDIR -type f -exec chmod 755 {} \;

#chmod -R 775 $INSTALLDIR
#
#
cat <<PROFILE > /root/.profile
export PATH=$SCRIPTSDIR:$PATH
export NO_AT_BRIDGE=1

[[ -f /home/$SUDO_USER/.Xauthority ]] && xauth -f /home/$SUDO_USER/.Xauthority list $DISPLAY | tail -1 | xargs xauth add

if [ "$BASH" ]; then
  if [ -f ~/.bashrc ]; then
    . ~/.bashrc
  fi
fi

mesg n || true
PROFILE

cat <<BASHRC > /root/.bashrc
# ~/.bashrc: executed by bash(1) for non-login shells.

# Note: PS1 and umask are already set in /etc/profile. You should not
# need this unless you want different defaults for root.
# PS1='\${debian_chroot:+($debian_chroot)}\\h:\\w\\\$ '
# umask 022

# You may uncomment the following lines if you want 'ls' to be colorized:
# export LS_OPTIONS='--color=auto'
# eval "\`dircolors\`"
# alias ls='ls \$LS_OPTIONS'
# alias ll='ls \$LS_OPTIONS -l'
# alias l='ls \$LS_OPTIONS -lA'
#
# Some more alias to avoid making mistakes:
# alias rm='rm -i'
# alias cp='cp -i'
# alias mv='mv -i'
#
# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=10000
HISTFILESIZE=20000
HISTTIMEFORMAT="%d/%m/%y %T "

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize


# BEGIN ANSIBLE MANAGED BLOCK
wk () {
  [ "\$#" == "0" ] && return;
  local ln=\$1;
  local home=/home/\$SUDO_USER

  [ -f \$home/.ssh/authorized_keys ] && {
      cat \$home/.ssh/authorized_keys | sed -n "\${ln}p" | cut -d ' ' -f3;
  }
}

BASHRC


[[ -f $INSTALLDIR/pkgs/pv_1.6.6-1+b1_amd64.deb ]] && dpkg -i $INSTALLDIR/pkgs/pv_1.6.6-1+b1_amd64.deb || die "cant' t install pv meter package!"

if [ ! -f $DEFAULTCFG  ]; then

cat <<EOF>$DEFAULTCFG
vm_password=$vm_password
ns1=$ns1
ns2=$ns2
domain=$domain
vm_mask=$vm_mask
vm_user=$vm_user
EOF

chmod 0600 $DEFAULTCFG

fi

chown -R $CLOUD_USER:$CLOUD_USER $INSTALLDIR
pdpl-file -R -r 0:0:0:0 /var/123-cloud/


if [[ -d $INSTALLDIR/keys/root/.ssh ]]; then 
       	cp -rp $INSTALLDIR/keys/root/.ssh /root/ && chown -R root:root /root/.ssh 
        chown -R root:root /root/.ssh
	chmod 600 /root/.ssh/id_rsa

else
	die "cant' t install keys for root!"
fi

if [[ -d $INSTALLDIR/keys/$SUDO_USER/.ssh ]]; then
      cp -rp $INSTALLDIR/keys/$SUDO_USER/.ssh /home/$SUDO_USER/ 
      chown -R $SUDO_USER:$SUDO_USER /home/$SUDO_USER/.ssh
else
      die "cant' t install keys for $SUDO_USER!"
fi

cp /home/$(cat /etc/passwd | grep $SUDO_UID | cut -d':' -f1)/.ssh/authorized_keys $INSTALLDIR/auth || die "Can't find SUDO_UID $SUDO_UID authorized_keys for init"
chmod 0600 $AUTHDIR/authorized_keys

#vi: set ts=2
