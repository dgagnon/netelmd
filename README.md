### What is NetelMD
NetelMD is a drop-in replacement for hardware RAID solutions using UDEV and MDADM on linux.

### Requirements
* MDADM
* UDEV
* sfdisk
* blockdev
* sgpio
* lsscsi
* python
* smartctl
* base64
* hdparm
* ipmi-chassis


### Installation
+ Run "install.sh"
+ Run "netelmd buildconf"


### Limitation
Currently supports only 2 drives RAID1.

Tested only on HP DL160 with onboard controller in AHCI mode on CentOS 6 amd64

