#!/bin/bash

INSTALLDIR=${INSTALLDIR:-/var/123-cloud}
SCRIPTSDIR=${SCRIPTSDIR:-/var/123-cloud/scripts}

eval $(PERL5LIB=$SCRIPTSDIR/ perl -Mutils -e 'utils::fill_env()');
[[ -f $SCRIPTSDIR/123-utils.sh ]] && source $SCRIPTSDIR/123-utils.sh

export LANG=C
prog=$(basename $0)

#mkdir -p $INSTALLDIR
#mkdir -p $SCRIPTSDIR
#mkdir -p $VMCONFIGDIR
#mkdir -p $TEMPLATESDIR
#mkdir -p $AUTHDIR
#chown -R $CLOUD_USER:$CLOUD_USER $INSTALLDIR

#find $INSTALLDIR -type d -exec chmod 775 {} \;
#find $INSTALLDIR -type f -exec chmod 664 {} \;
#find $SCRIPTSDIR -type f -exec chmod 755 {} \;

#chmod -R 775 $INSTALLDIR

if [ ! -f $DEFAULTCFG  ]; then

cat <<EOF>$DEFAULTCFG
vm_password=$vm_password
ns1=$ns1
ns2=$ns2
domain=$domain
vm_mask=$vm_mask
vm_user=$vm_user
EOF

cp /home/$(cat /etc/passwd | grep $SUDO_UID | cut -d':' -f1)/.ssh/authorized_keys $INSTALLDIR/auth || die "Can't find SUDO_UID $SUDO_UID authorized_keys for init"

chmod 0600 $DEFAULTCFG
chmod 0600 $AUTHDIR/authorized_keys

chown -R $CLOUD_USER:$CLOUD_USER $INSTALLDIR

fi

#pdpl-file -R -r 0:0:0:0 /var/123-cloud/

. $DEFAULTCFG

# vim: ts=2 sw=2 et :
