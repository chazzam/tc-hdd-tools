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

identify_3ware() {
  checkroot;
  if [ "$(lsmod|grep 3w_xxxx|wc -l)" -lt 1 ]; then
    modprobe 3w_xxxx;
    sleep 2;
  fi;
  local controller="$(
      tw_cli show|
      tail -n+4|sed -e 's/\s\s\+/,/g;'|
      cut -d, -f1
  )"
  local drives="$(
      tw_cli /${controller} show drivestatus|
      tail -n+4|sed -e 's/\s\s\+/,/g;'|
      cut -f5 -d,
  )"
  local drive=;
  local i=0;
  for drive in $drives; do
    RAID_ARGS[$i]="-d 3ware,${drive}";
    RAID_DRIVES[$i]="$drive";
    i=$(expr $i + 1);
  done;
  SDXS="$(
    file -sL /dev/tw*|
    grep -v 'writable, no read permission'|
    cut -d: -f1
  )";
}

identify_adaptec() {
  # /dev/sg0 is the actual controller or something, disks start at sg1
  SDXS="$(
    ls /dev/sg*|
    sed -e 's#/dev/sg0##'
  )";
  local drive=;
  local i=0;
  for drive in $SDXS; do
    RAID_ARGS[$i]="-d sat";
    RAID_DRIVES[$i]="no";
    i=$(expr $i + 1);
  done;
}

identify_lsi(){
  local found=;
  found="$(smartctl --scan-open|grep -v 'failed'|cut -d\  -f1-3)";
  [ -z "$found" ] && return 1;
  local drives=
  readarray -t drives <<<"$found"
  #IFS=$'\n' read -rd '' -a drives <<<"$found"
  local drive=;
  local i=0;
  for args in "${drives[@]}"; do
    local vol="$(echo $args | cut -d\  -f1)";
    local drive="$(echo $args | cut -d\  -f2-3)";
    if [[ $SDXS != *"$vol"* ]]; then
      SDXS="$SDXS $vol";
    fi;
    RAID_ARGS[$i]="$drive";
    RAID_DRIVES[$i]="${drive##*,}";
    i=$(expr $i + 1);
  done;

}

identify_raid() {
  THREEWARE="$(lspci -d 13c1:*|wc -l)"
  ADAPTEC="$(lspci -d 9005:*|wc -l)";
  LSI="$(lspci -d 1000:*|wc -l)";
  RAID_PRESENT="$(expr $THREEWARE + $ADAPTEC + $LSI)";
  if [ "$THREEWARE" -gt 0 ]; then
    identify_3ware;
  elif [ "$ADAPTEC" -gt 0 ]; then
    identify_adaptec;
  elif [ "$LSI" -gt 0 ]; then
    identify_lsi;
  fi
}

