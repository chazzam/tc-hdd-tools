#!/bin/bash
# Written by Charles Moye cmoye@digium.com
# Copyright 2012-2015 Charles Moye
#
#Licensed under the Apache License, Version 2.0 (the "License");
#you may not use this file except in compliance with the License.
#You may obtain a copy of the License at
#
#	http://www.apache.org/licenses/LICENSE-2.0
#
#Unless required by applicable law or agreed to in writing, software
#distributed under the License is distributed on an "AS IS" BASIS,
#WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#See the License for the specific language governing permissions and
#limitations under the License.

. /etc/init.d/tc-functions;

SUDO=$(which sudo);
SMARTCTL=$(which smartctl);

list_sdxn() {
  checkroot;
  SDX_VOLS="$(fdisk -l /dev/sd* 2>&1 | 
      grep Linux|grep -v LVM|awk '{print $1; }')
      ";
}

list_disks() {
  checkroot;
  SDXS="$(fdisk -l /dev/sd? 2>&1 |
    grep -Ev 'No such device|Cannot open|identifier'|grep Disk|
    awk '{print $2; }' | sed -e 's/://g'|sort|uniq;
  )";
}

list_lvm() {
  checkroot;
  /usr/local/sbin/vgchange -ay
  sleep 2
  LVM_VOLS="$(lvdisplay | grep 'LV Name'|awk '{print $3; }')";
}

filesystem_type() {
  checkroot;
  local vol="$1"
  [ -z $vol ] && FILE_TYPE="" && return 1;
  FILE_TYPE="$(file -sL $vol | sed -e 's/.*\(swap\|ext.\).*/\1/')";
}

