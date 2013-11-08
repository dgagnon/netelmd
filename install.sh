#!/bin/bash
cp 99-netelmd.rules /etc/udev/rules.d/
cp 05-netelmd.rules /etc/udev/rules.d/
cp netelmd.sh /sbin/netelmd
cp shyml.py /sbin/shyml
sed -i 's#DEBUG=.*#DEBUG=false#' /sbin/netelmd
sed -i 's#DRYRUN=.*#DRYRUN=false#' /sbin/netelmd
sed -i 's#ECHOOUT=.*#ECHOOUT=false#' /sbin/netelmd
sed -i 's#LOGFILE=.*#LOGFILE="/var/log/netelmd.log"#' /sbin/netelmd
sed -i 's#^CONFFILE=.*#CONFFILE="/etc/sysconfig/netelmd.yml"#' /sbin/netelmd
grep PROGRAM /etc/mdadm.conf >/dev/null 2>/dev/null
if [[ "$?" -eq 0 ]];then
	sed -i 's%(#PROGRAM|PROGRAM) .*%PROGRAM /sbin/netelmd%g' /etc/mdadm.conf
else
	echo "PROGRAM /sbin/netelmd" >> /etc/mdadm.conf
fi
/etc/init.d/mdmonitor reload

grep netelmd /etc/rc.local >/dev/null 2>/dev/null
if [[ "$?" -eq 0 ]];then
	sed -i 's%netelmd.*%netelmd boot >/dev/null 2>&1%g' /etc/rc.local
else
	echo "netelmd boot >/dev/null 2>&1" >> /etc/rc.local
fi

chmod +x /sbin/netelmd
udevadm control --reload-rules
