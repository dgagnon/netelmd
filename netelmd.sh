#!/bin/bash
#set -e
#set -x
DEBUG=true
DRYRUN=false
ECHOOUT=false
LOGFILE="/var/log/netelmd.log"
NEEDEDPROG="mount grep awk udevadm mdadm mv which env sfdisk blockdev sgpio lsscsi python shyml smartctl base64 hdparm ipmi-chassis"
PMODULES="yaml"
CONFFILE="/etc/sysconfig/netelmd.yml"
BAKCONFFILE="/root/.netelmd.yml.bak"
LOCKFILE="/var/run/netelmd.lock"
declare ERRNUM=0
declare -a ERRMSG

function output () {
    if [[ $DRYRUN == "false" && $ECHOOUT == "false" ]]; then
        $1 >> $OUTPUT 2>&1
    elif [[ $DRYRUN == "false" && $ECHOOUT == "true" ]]; then
        $1 | tee -a $OUTPUT
    elif [[ $DRYRUN == "true" ]]; then
        echo "$1"
    fi
}

function nothing () {
    output "echo Doing nothing"
    return 0
}

function getvar () {
    echo $(shyml $CONFFILE get-value $1)
}

function setvar () {
    shyml $CONFFILE add-value "$1" "$2"    
}

function getnamefrompid () {
    ps -p${1} -o args=
}

function error () {
    # [[ "$#" -lt 1 ]] && output "echo error called without argument" && return 1
    ERRNUM=$ERRNUM+1
    # ERRMSG=("${ERRMSG[@]}" "$1")
}

function top_level_parent_pid {
    # Look up the parent of the given PID.
    pid=${1:-$$}
    stat=($(</proc/${pid}/stat))
    ppid=${stat[3]}

    if [[ $(getnamefrompid ${ppid}) =~ .*udev.* || "$(getnamefrompid ${ppid} )" =~ .*mdadm.* ]] ; then
        getnamefrompid ${ppid} 
    else
        top_level_parent_pid ${ppid}
    fi
}

function getidbydev () {
    # output "echo getidbydev called"
    if ! [[ $1 =~ ^sd[a-z]$ && -b /dev/$1 ]];then
        output "echo you need a valid device name, $1 is not"
        error
        return 1
    fi
    echo $(lsscsi | grep $1 | awk '{print $1}' | tr -d "[]" | awk -F":" '{print $1}')
}

function chassis_light () {
    output "ipmi-chassis --chassis-identify=$1"
}

function check_bl () {
    bl=0
    model="$(udevadm info --query=all --name=$1 | grep -o -E "ID_MODEL=([a-zA-Z0-9\_]*)" | awk -F'=' '{print $2}')"
    case "$model" in
        *iSCSI) bl=1;;
        *) bl=0;;
    esac
    echo $bl
}

function light () {
    output "echo Light was called"
    if [[ ! $2 =~ ^(off|fault|rebuild)$ ]];then
        output "echo you need a valid action, $2 is not"
        error
        return 1
    fi

    getvar "raid.members" | grep $1 >/dev/null 2>&1
    RETCODE=$?
    if [[ ! $1 =~ ^sd[a-z]$ && ! -b /dev/$1 && "$RETCODE" -gt 0 ]];then
        output "echo you need a valid device name, $1 is not"
        error
        return 1
    elif [[ "$RETCODE" -eq 0 && -b /dev/$1 ]];then
        OLDID="$(getvar raid.$1.id)"
        CURID="$(getidbydev $1)"
        if [[ "$CURID" == "$OLDID" ]];then
            output "echo Light for $1 is currently $(getvar raid.$1.light)"
            setvar "raid.$1.light" "$2"
            output "echo Setting ${2} light for ${1} by device name"
            output "sgpio -d${1} -s${2}"
        else
            output "echo Device $1 has changed from port ${OLDID} to ${CURID}"
            output "echo Shutting off light on old port"
            output "sgpio -p${OLDID} -soff"
            output "echo Setting ${2} light for ${1} by port number ${CURID} and update config"            
            output "sgpio -p${CURID} -s${2}"
            setvar "raid.${1}.id" "$CURID"
        fi
    elif [[ "$RETCODE" -eq 0 && ! -b /dev/$1 ]];then
        output "echo Device does not exist anymore"
        output "echo Setting ${2} light for ${1} by port number $(getvar raid.$1.id)"            
        output "sgpio -p$(getvar raid.$1.id) -s${2}"
    elif [[ "$RETCODE" -eq 1 && -b /dev/$1 ]];then
        output "echo Device exist, but not in RAID members"
        output "echo Setting ${2} light for ${1} by device name"            
        output "sgpio -d${1} -s${2}"    
    else
        output "echo this should not happen"
        output "echo retcode: $RETCODE"
        [[ -b /dev/$1 ]] && output "echo device is present"
        [[ ! -b /dev/$1 ]] && output "echo device is not present"
        error
        return 1
    fi
    # BUG: need to find way to universalize this
    for i in {2..5};do
        STAYON=0
        for did in $(lsscsi | awk '{print $1}' | tr -d "[]" | awk -F":" '{print $1}');do
            if [[ "$i" == "$did" ]];then
                STAYON=$STAYON+1
                break
            fi
        done
        if [[ $STAYON -eq 0 ]];then
            output "sgpio -p$i -soff"
        fi
    done
}

function buildconf () {
    output "echo buildconf was called"
    if [[ -a "$CONFFILE" ]];then
        output "echo Saving backup config to $BAKCONFFILE"
        if [[ -a "$BAKCONFFILE" ]];then
            output "rm -f $BAKCONFFILE"
        fi
        output "mv -f $CONFFILE $BAKCONFFILE"
    fi

    RAIDMDSTMP="$(ls /dev/md[0-9]*)"
    setvar raid.raidmds "$(echo $RAIDMDSTMP | sed 's#/dev/##g' | tr "\t" " ")"
    GLOBALLIST=""
    for i in $(getvar raid.raidmds);do
        setvar "raid.${i}.size" "$(mdadm --detail /dev/md0 | grep "Array Size" | awk '{print $4}')"
        setvar "raid.${i}.usedsize" "$(mdadm --detail /dev/md0 | grep "Used Dev Size" | awk '{print $5}')"
        setvar "raid.${i}.activedev" "$(mdadm --detail /dev/$i | grep 'Active Devices' | awk '{print $4}')"
        setvar "raid.${i}.workingdev" "$(mdadm --detail /dev/$i | grep 'Working Devices' | awk '{print $4}')"
        setvar "raid.${i}.faileddev" "$(mdadm --detail /dev/$i | grep 'Failed Devices' | awk '{print $4}')"
        setvar "raid.${i}.level" "$(mdadm --detail /dev/$i | grep 'Raid Level' | awk '{print $4}')"
        [[ $(getvar "raid.${i}.level") != "raid1" ]] && output "echo WARNING: Only RAID1 is supported at the moment." && error && return 1
        setvar "raid.${i}.state" "$(mdadm --detail /dev/$i | grep 'State' | awk -F':' '{print $2}' | tr -d " " | grep -o -E '[a-z,]*')"
        setvar "raid.${i}.metadata" "$(mdadm --detail /dev/$i | grep 'Version' | awk -F':' '{print $2}' | grep -o -E '[0-9\.]*')"
        setvar "raid.${i}.mount" "$(grep /dev/$i /proc/mounts | awk '{print $2}')"
        setvar "raid.${i}.uuid" "$(mdadm --detail /dev/$i | grep UUID | awk '{print $3}')"
        CURCOUNT=$(getvar "raid.${i}.activedev")-$(getvar "raid.${i}.workingdev")+$(getvar "raid.${i}.faileddev")

       if [[ $CURCOUNT -eq 0 && ! "$(getvar "raid.${i}.state")" =~ ".*degraded.*" ]];then
            LIST=""
            for i2 in $(mdadm --detail /dev/$i | grep 'active sync' | awk '{print $7}' | sed 's#/dev/##g');do
                setvar "raid.${i}.member.${i2}.size" "$(blockdev --getsz /dev/$i2)"
                LIST="$LIST $i2"
            done
            GLOBALLIST="$GLOBALLIST $LIST"
        else
            output "echo Some arrays have failed members"
            return 1
        fi
        setvar "raid.${i}.members" "$(echo $LIST | sed 's/^ //')"
    done

    setvar "raid.members" "$(echo $GLOBALLIST|grep -o -E 'sd[a-z]*'|sort|uniq|tr "\n" " " | sed 's/ $//')"
    for i in $(getvar "raid.members");do
        setvar "raid.${i}.size" "$(blockdev --getsize /dev/$i)"
        setvar "raid.${i}.id" "$(getidbydev $i)"
        setvar "raid.${i}.light" "off"
        setvar "raid.${i}.model" "$(udevadm info --query=all --name=$i | grep -o -E "ID_MODEL=([a-zA-Z0-9\_]*)" | awk -F'=' '{print $2}')"
        setvar "raid.${i}.serial" "$(smartctl -a /dev/$i | grep Serial | awk '{print $3}')"
        setvar "raid.${i}.health" "$(smartctl -a /dev/$i | grep health | awk '{print $6}')"
        setvar "raid.${i}.ptable" "$(sfdisk -d /dev/$i | base64)"
        setvar "raid.${i}.mbr" "$(dd \if=/dev/$i of=/dev/stdout bs=512 count=1 2>/dev/null | base64)"
    done
}

function resetdisk () {
    output "echo resetdisk was called"
    if ! [[ $1 =~ ^sd[a-z]$ && -b /dev/$1 ]];then
        output "echo you need a valid device name, $1 is not"
        error
        return 1
    fi
    grep $1 /proc/mdstat >/dev/null 2>&1
    RETCODE=$?
    if [[ $RETCODE -eq 0 && "$2" != "force" ]];then
        output "echo Device is still active in mdstat" && error && return 1
    elif [[ $RETCODE -gt 0 || "$2" == "force" ]];then
        output "mdadm --zero-superblock /dev/$1"
        output "dd if=/dev/zero of=/dev/$1 bs=512 count=1"
        output "partprobe /dev/$1"
    else
        output "echo this should not happen" && error && return 1
    fi
    fail $1 force
#    setvar "raid.${1}.light" "fault"
#    output "sgpio -p$(getvar "raid.${1}.id") -s fault"
    output "echo resetdisk on $1 done"
}

function fail () {
    output "echo Failed was called"
    if ! [[ $1 =~ ^sd[a-z]$ ]];then
        output "echo you need a valid device name: $1"
        error
        return 1
    fi

    grep $1 /proc/mdstat >/dev/null 2>&1
    RETCODE=$?
    [[ "$RETCODE" -gt 0 && "$2" != "force" ]] && output "echo Device is not active in any raid." && error && return 1
    output "echo Device $1 is active in at least one array"

    getvar "raid.members" | grep $1 >/dev/null 2>&1
    RETCODE=$?
    if [[ "$RETCODE" -gt 0 && "$2" != "force" ]]; then
        output "echo Device not in saved RAID config." && error && return 1
    elif [[ "$RETCODE" -gt 0 && ! -b /dev/$1 && "$2" == "force" ]]; then
        output "echo Device not in saved RAID config and not in /dev, continuing with a device change"
        DEVICECHANGE=true
        # BUG: this needs to be fixed for other raid levels
    iter=0
        for i in $(getvar "raid.members");do
            if [[ -b /dev/$i ]];then
                ISACTIVE=$i
                output "echo Device $i is available"
        iter=$iter+1
            else
                ISDEAD=$i
                output "echo Device $i is not available"
            fi
        done
    [[ "$iter" != 0 ]] && output "echo Two devices are available, this should not happen" && error && return 1
        SOURCEDEV=$ISDEAD
    else
        SOURCEDEV=$1
    fi

    didit=0
    for i in $(getvar raid.raidmds);do
        if [[ $DEVICECHANGE == "true" ]];then
            PARTDEV=$(getvar raid.${i}.members | grep -o "${SOURCEDEV}[0-9*]" |sed "s#$ISDEAD#$1#g")
            output "echo Detected devicechange, setting partdev to $PARTDEV"
        else
            PARTDEV=$(getvar raid.${i}.members | grep -o "${SOURCEDEV}[0-9*]")
            output "echo partdev is $PARTDEV"
        fi
        output "echo Failing $PARTDEV in $i"
        output "mdadm --fail /dev/$i $PARTDEV"
        RETCODE=$?
        [[ $RETCODE -eq 0 ]] && ((didit++))
        output "echo Removing $PARTDEV in $i"
        output "mdadm --remove /dev/$i $PARTDEV"
        output "echo Removing and Failing detached in $i"
        output "mdadm --fail /dev/$i detached --remove detached"
    done
    
    if [[ "$didit" -lt 1 ]];then
        output "echo No device failed."
    else
        output "echo Failed $didit devices"
    fi
    chassis_light FORCE
    light $1 "fault"
}

function add () {
    output "echo add was called"
    if ! [[ $1 =~ ^sd[a-z]$ && -b /dev/$1 ]];then
        output "echo you need a valid device name, $1 is not"
        error
        return 1
    fi
    grep $1 /proc/mdstat >/dev/null 2>&1
    RETCODE=$?
    if [[ $RETCODE -eq 0 && "$2" != "force" ]];then
        output "echo Device is still active in mdstat" && error && return 1
    elif [[ ! "$(getvar raid.members)" =~ $1 ]];then
        output "echo Device is not listed in config, doing a Device change."
        DEVICECHANGE=true
        for i in $(getvar raid.members);do
            if [[ -b /dev/$i ]];then
                ISACTIVE=$i
                output "echo Device $i is available"
            else
                ISDEAD=$i
                output "echo Device $i is not available"
            fi
        done
        SOURCEDEV=$ISDEAD
        [[ "$2" != "force" ]] && error && return 1
    else
        SOURCEDEV=$1
    fi

    didit=0 
    for i in $(getvar raid.raidmds);do
        output "echo Doing $i"
        if [[ $DEVICECHANGE == "true" ]];then
            PARTDEV=$(getvar raid.${i}.members | grep -o -E "${SOURCEDEV}[0-9]*" |sed "s#$ISDEAD#$1#g")
            output "echo Detected devicechange, setting partdev to $PARTDEV"
        else
            PARTDEV=$(getvar raid.${i}.members | grep -o -E "${SOURCEDEV}[0-9]*")
            output "echo partdev is $PARTDEV"
        fi
 
        if [[ "$(mdadm -E /dev/$PARTDEV | grep "Array UUID" | awk '{print $4}')" == "$(getvar raid.$i.uuid)" ]] || [[ "$2" == "force" ]];then
            output "echo Adding $PARTDEV to $i"
            output "mdadm --add /dev/$i /dev/$PARTDEV"
            RETCODE=$?
            [[ $RETCODE -eq 0 ]] && ((didit++))
        else
            output "echo UUID don't match" && error && return 1
        fi
    done
    

    if [[ "$didit" -lt 1 ]];then
        output "echo No device added."
    else
        output "echo Added $didit devices"        
    fi
}

function rebuildstarted () {
    output "echo RebuildStarted was called"
    for i in $(mdadm --detail /dev/$1 | grep rebuilding | awk '{print $7}' | grep -o -E 'sd[a-z]');do
        light "$i" "rebuild"
    done
}

function rebuildfinished () {
    output "echo RebuildFinished was called"
    TMP=$(grep -E '(recovery|DELAYED)' /proc/mdstat)
    if [[ "$?" -eq 1 ]];then
        output "echo All mds are in sync"
        DEVCHANGE=0
        for i in $(mdadm --detail /dev/$1 | grep sync | awk '{print $7}' | grep -o -E 'sd[a-z]*');do
            light "$i" "off"
            TMP=$(grep "$i" "$(getvar "raid.members")")
            RETCODE=$?
            if [[ "$RETCODE" -gt 0 ]];then
                output "echo Detected a device change, will buildconf"
                DEVCHANGE=$DEVCHANGE+1
            fi
        done
        if [[ "$DEVCHANGE" -gt 0 ]];then
            output "echo Device changed detected, rebuilding config"
            output "echo ---------------------------"
            buildconf
            output "echo ---------------------------"
        fi
        chassis_light TURN-OFF
    else
        output "echo Some mds are still not synced"
    fi
}

function boot () {
    output "echo boot was called"

    for i in $(ls /dev/sd*|grep -o -E 'sd[a-z]*'|sort|uniq);do
        output "echo ---------------------------"
        rebuild $i
        output "echo ---------------------------"
    done
}

function rebuild () {
    output "echo rebuild was called"
    ls /dev/${1}[0-9]* >/dev/null 2>&1
    RETCODE=$?
    if ! [[ $1 =~ ^sd[a-z] && -b /dev/$1 ]];then
        output "echo you need a valid device name, $1 is not"
        return 1
    elif [[ "$(getvar raid.${1}.serial)" == "$(smartctl -a /dev/${1} | grep Serial | awk '{print $3}')" ]] && [[ "$RETCODE" -eq 0 ]]; then
        output "echo Serials are matching, adding to the arrays"
        output "echo ---------------------------"
        add $1
        output "echo ---------------------------"
        return 0
    elif [[ $RETCODE -eq 0 && "$2" != "force" ]]; then
        output "echo Disk $1 not empty and force argument not present" && error && return 1
    elif [[ $RETCODE -eq 0 && "$2" == "force" ]]; then
        #output "echo Drive $1 is dirty, let's reset it."
        # resetdisk $1 force
        output "echo Drive has a partition table, try adding the partitions in the RAID"
        output "echo ---------------------------"
        add $1 force
        output "echo ---------------------------"
        return 0
    fi

    getvar "raid.members" | grep $1 >/dev/null 2>&1
    RETCODE=$?
    if [[ "$RETCODE" -gt 0 && "$2" != "force" ]]; then
        output "echo Device not in RAID config." && error && return 1
    elif [[ "$RETCODE" -gt 0 && "$2" == "force" ]]; then
        output "echo Device not in RAID config, forcing a device change"
        DEVICECHANGE=true
        for i in $(getvar "raid.members");do
            if [[ -b /dev/$i ]];then
                ISACTIVE=$i
            else
                ISDEAD=$i
            fi
        done
        SOURCEDEV=$ISACTIVE
    else
        SOURCEDEVTMP="$(getvar "raid.members" | sed "s/$1//g" | sed "s/ //g" )"
        SOURCEDEV=${SOURCEDEVTMP:0:3}
    fi

    [ ! -b /dev/$SOURCEDEV ] && output "echo Source device /dev/$SOURCEDEV is invalid" && error && return 1



    grep $SOURCEDEV /proc/mdstat >/dev/null 2>&1
    RETCODE=$?
    [[ "$RETCODE" -gt 0 && "$2" != "force" ]] && output "echo Source device is not active in any raid." && error && return 1

    SOURCESIZE=$(getvar "raid.$SOURCEDEV.size")
    DESTSIZE=$(blockdev --getsize /dev/$1)
    [[ $SOURCESIZE -ne $DESTSIZE && "$2" != "force" ]] && output "echo Devices are not the same size." && error && return 1

    output "echo 'sfdisk -d /dev/$SOURCEDEV | sfdisk --force /dev/$1'"
    sfdisk -d /dev/$SOURCEDEV | sfdisk --force /dev/$1 >/dev/null 2>&1
    #sleep 5
  #  partprobe /dev/$1
    #sleep 5
    output "echo ---------------------------"
    add $1 force
    output "echo ---------------------------"
}

function remove () {
    output "echo Remove was called"
    # fail $1 $2
    light $1 off
}

function print () {
    output "echo  print was called"
    cat /proc/mdstat
}

function smart () {
    if [[ -z "$1" || -z "$2" ]];then
        output "echo action or device missing"
        error
        return 1
    fi

    case $1 in
        check ) output "smartctl -a /dev/$2";;
    esac

}

function wcache () {
    if [[ -z "$1" || -z "$2" ]];then
        output "echo action or device missing"
        error
        return 1
    fi
    output "hdparm -W$1 /dev/$2"
}

# Get exclusive lock and be prepare to wait 60 seconds for it, bail-out if it doesnt work
(
flock -x -w 60 90
if [ "$?" != "0" ];then echo "Cannot acquire lock!"; exit 1; fi

if [[ "$DEBUG" == "true" ]]; then
    OUTPUT=$LOGFILE
    echo "-----------------------Started at $(date)----------------------------" >> $LOGFILE
    echo "$$ - $(getnamefrompid $$)" >> $LOGFILE
    echo "" >> $LOGFILE

elif [[ $DEBUG == "false" ]]; then
    OUTPUT="/dev/null"
fi

# path is too restricted when ran from udev
[[ "$PATH" == "/usr/local/bin:/bin:/usr/bin" ]] && export PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin"

# Bail-out if any needed executables are missing
for i in $NEEDEDPROG;do
    CURPATH=`/usr/bin/which $i`
    if [ ! -x "$CURPATH" ];then
        output "echo 'Missing $i'";
        error
        exit 1;
    CURPATH=''
    fi
done

# Bail-out if any needed python module are missing
for i in $PMODULES;do
    python -c"import $i" >/dev/null 2>&1
    if [[ $? -ne 0 ]];then
        output "echo 'Missing python module $i'";
        error
        exit 1;
    fi
done

# Arguments are different when ran from cli/udev/mdmon
fd=0   # stdin
if [[ -t "$fd" || -p /dev/stdin ]]; then
    output "echo Ran from cli"
    if [ $# -lt 0 ];then
        output "echo 'Must specify an action'"
        error
        exit 1
    else
        ACTION="$1"
        DEVICE="$2"
        FORCE="$3"
    fi
else
    if [[ $(top_level_parent_pid) =~ .*udev.* ]];then
        output "echo Ran from udevd"
        ACTION="$ACTION"
        DEVICE="$(echo $DEVNAME | grep -o -E 'sd[a-z]*|md[0-9]*' )"
        FORCE=""
    elif [[ $(top_level_parent_pid) =~ .*mdadm.* ]];then
        output "echo Ran from mdmonitor"
        ACTION="$(echo $1|tr '[:upper:]' '[:lower:]')"
        DEVICE="$(echo $2|grep -o -E 'sd[a-z]*|md[0-9]*')"
        FORCE=""
        [[ "$DEVICE" =~ md[0-9]* && "$3" =~ .*sd[a-z]* ]] && DEVICE="$(echo $3|grep -o -E 'sd[a-z]*')"
        [[ -z "$DEVICE" && ! -z "$3" ]] && DEVICE="$(echo $3|grep -o -E 'sd[a-z]*')"
    else
        output "echo This should not happen"
        output "echo Ran from $(top_level_parent_pid)"
        exit 1
    fi    
fi

# Create config if it does not exist
if [[ "$ACTION" != "buildconf" ]];then
    if [[ ! -a "$CONFFILE" ]];then
        output "echo must create config file first"
        buildconf
    fi
fi

# Check if device has been blacklisted

RET=$(check_bl "$DEVICE")
if [[ $RET > 0 ]];then
    output "echo $DEVICE has been blacklisted by model"
    error
else

case "$ACTION" in
    buildconf) buildconf;;
    resetdisk) resetdisk $DEVICE $FORCE;;
    fail) fail $DEVICE $FORCE;;
    add) rebuild $DEVICE $FORCE;;
    rawadd) add $DEVICE $FORCE;;
    rebuildfinished) rebuildfinished $DEVICE;;
    rebuildstarted) rebuildstarted $DEVICE;;
    boot) boot;;
    remove) remove $DEVICE $FORCE;;
    status) print;;
    fullstatus) smart check $DEVICE;;
    light) light $DEVICE $FORCE;;
    devicedisappeared) fail $DEVICE $FORCE;;
    failspare) fail $DEVICE $FORCE;;
    spareactive) nothing;;
    enablecache) wcache 1 $DEVICE;;
    disablecache) wcache 0 $DEVICE;;
    change) nothing;;
    *) output "echo 'Usage: netelmd (resetdisk|buildconf|add|addraw|fail|remove|rebuildfinished|rebuildstarted) sd[a-z] [force]'";;
esac
fi
if [[ "$DEBUG" == "true" ]]; then
    echo "" >> $LOGFILE
    echo "Action was: $ACTION" >> $LOGFILE
    echo "Device was: $DEVICE" >> $LOGFILE
    echo "Force was: $FORCE" >> $LOGFILE
    echo "$$ - $(getnamefrompid $$)" >> $LOGFILE
    [[ "$ERRNUM" -gt 0 ]] && output "echo Automd executed with errors" 
    echo "-----------------------Stopped at $(date)----------------------------" >> $LOGFILE
fi
[[ "$ERRNUM" -gt 0 ]] && exit 1

exit 0
) 90>$LOCKFILE

RETCODE=$?
#[[ "$RETCODE" -gt 0 ]] && echo "Something went wrong in the subshell" && exit 1
[[ "$RETCODE" -gt 0 ]] && exit 1
