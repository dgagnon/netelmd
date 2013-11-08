#!/bin/bash
cp 99-automd.rules /etc/udev/rules.d/
cp 05-automd.rules /etc/udev/rules.d/
cp automd.sh /sbin/automd
cp shyml.py /sbin/shyml
sed -i 's#DEBUG=.*#DEBUG=false#' /sbin/automd
sed -i 's#DRYRUN=.*#DRYRUN=false#' /sbin/automd
sed -i 's#ECHOOUT=.*#ECHOOUT=false#' /sbin/automd
sed -i 's#LOGFILE=.*#LOGFILE="/var/log/automd.log"#' /sbin/automd
sed -i 's#^CONFFILE=.*#CONFFILE="/etc/sysconfig/automd.yml"#' /sbin/automd
grep PROGRAM /etc/mdadm.conf >/dev/null 2>/dev/null
if [[ "$?" -eq 0 ]];then
	sed -i 's%(#PROGRAM|PROGRAM) .*%PROGRAM /sbin/automd%g' /etc/mdadm.conf
else
	echo "PROGRAM /sbin/automd" >> /etc/mdadm.conf
fi
/etc/init.d/mdmonitor reload

grep automd /etc/rc.local >/dev/null 2>/dev/null
if [[ "$?" -eq 0 ]];then
	sed -i 's%automd.*%automd boot >/dev/null 2>&1%g' /etc/rc.local
else
	echo "automd boot >/dev/null 2>&1" >> /etc/rc.local
fi

chmod +x /sbin/automd
udevadm control --reload-rules
