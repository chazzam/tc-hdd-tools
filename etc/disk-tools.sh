#!/bin/bash
# Written by Charles Moye cmoye@digium.com
# Copyright 2012-2016 Charles Moye
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
LOG_DIR="/tmp/tools"
[ -d $LOG_DIR ] || mkdir -p $LOG_DIR

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

identify_drives() {
  if [ "$(lsmod|grep 3w_xxxx|wc -l)" -lt 1 ]; then
    modprobe 3w_xxxx;
    sleep 2;
  fi;
  echo "" > /tmp/drives_safe;
  local adaptec_raw="$(ls -1 /dev/sg*|sed -e 's#/dev/sg0##;s#^\s*$##;s/sg\([0-9]\+\)/sg\1 -d sat/;')"
  local found_raw="$(smartctl --scan-open|grep -v '^#'|cut -d# -f1)"
  [ -z "$found_raw" ] && return 1;
  local drives_raw=""
  readarray -t drives_raw <<<"$found_raw $adaptec_raw"

  local i=0;
  for dr in "${drives_raw[@]}"; do
    # Require it to be available, not to have failed, and to have a self-assessment
    [ -z "$(smartctl -a $dr|grep SMART|grep Available)" ] && continue;
    [ -z "$(smartctl -a $dr|grep SMART|grep 'command failed')" ] || continue;
    [ -z "$(smartctl -a $dr|grep SMART|grep 'self-assessment')" ] && continue;
    local serial="$(smartctl -a $dr|
      grep -i 'serial number'|
      sed -e "s/\s\+/ /g"|
      cut -d\  -f3)";
    # Don't add this again if it already exists
    local exists_serial=0;
    for x in "${ALL_SMART_ID[@]}"; do
      [ "$x" = "$serial" ] && exists_serial=1 && break;
    done;
    [ "$exists_serial" = "1" ] && continue;
    dr="$(echo $dr|sed -e 's/^\s*//;s/\s*$//')"
    echo "$dr" >> /tmp/drives_safe
    ALL_SMART[$i]="${dr%% }";
    ALL_SMART_ID[$i]="$serial"
    ALL_CONVEYANCE[$i]="$($SMARTCTL -c $dr|
      grep -A10 'Offline data collection'|
      grep -A10 capabilities|
      grep -io 'Conveyance Self-test supported'|
      grep -io conveyance)"
    i=$(expr $i + 1);
  done;
  echo "" >> /tmp/drives_safe
}

smart_get_id() {
  local sdrive="$@";
  local id="";
  local i=0;
  for d in "${ALL_SMART[@]}"; do
    [ "$d" = "$sdrive" ] && id="${ALL_SMART_ID[$i]}"
    i=$(expr $i + 1);
  done
  echo "$id";
}

smart_init() {
  checkroot;
  local sdrive="$@";
  local id=$(smart_get_id $sdrive)
  [ -z "$id" ] && id="${sdrive%% *}";

  local vol="$(echo $sdrive|cut -d\  -f1)";
  local args="$(echo $sdrive|cut -d\  -f2-)";
  #echo -e "\n===============================================================================";
  echo "Initiating $id using $sdrive";
  $SMARTCTL -i $sdrive 2>&1|\
      grep -E 'Model Family:|Device Model:|Serial Number:|User Capacity:';
  $SMARTCTL -s on -S on -o on $sdrive 2>&1|grep SMART;
  #$SMARTCTL -c $sdrive;
  $SMARTCTL -H $sdrive 2>&1|grep "test result";
  echo -e "===============================================================================\n";
}

smart_test() {
  checkroot;
  local stest="$1";
  shift;
  local sdrive="$@";
  local id=$(smart_get_id $sdrive)
  [ -z "$id" ] && id="${sdrive%% *}";

  $SMARTCTL -t $stest $sdrive > /tmp/smart_test_time.txt
  SMART_TIME="$(grep -i 'please wait' /tmp/smart_test_time.txt|
    grep -Eio ' [0-9]+ (minutes|hours|days)')";
  echo "Test:$stest on ${id} should take about ${SMART_TIME## }."
}

smart_process() {
  local dr=
  local t=
  for dr in "${ALL_SMART[@]}"; do
    smart_init "$dr";
  done;
  for t in $TESTS; do
    local i=0;
    for dr in "${ALL_SMART[@]}"; do
      local id=$(smart_get_id $dr)
      [ -z "$id" ] && id="${dr%% *}";
      if [ "$t" = "conveyance" -a -z "${ALL_CONVEYANCE[$i]}" ]; then
        echo "Conveyance test not supported on $id"
      else
        smart_test "$t" "$dr";
      fi;
      i=$(expr $i + 1);
    done;
    smart_wait;
  done;
}

smart_running() {
  local sdrive="$@";
  local percent=$($SMARTCTL -cl selftest $sdrive|
        grep -A1 'Self-test execution'|
        grep "test remaining"|grep -o '[0-9]\+%')
  echo $percent;
}

smart_wait() {
  echo "Running..."
  local dr=
  local count=1;
  while [ "$count" -gt 0 ]; do
    local status=" "
    count=0
    for dr in "${ALL_SMART[@]}"; do
      local id=$(smart_get_id $dr)
      [ -z "$id" ] && id="${dr%% *}";
      local p="$(smart_running $dr)";
      if [ -z "$p" ]; then
        p="Done";
      else
        count=$(expr $count + 1);
      fi
      status="$status ${id}:$p ";
    done;
    echo "  $(date -u '+%Y%m%d-%R')${status}...";
    [ "$count" -eq "0" ] && break;
    sleep 30;
  done;
  for dr in "${ALL_SMART[@]}"; do
    smart_check "$dr";
  done;
  echo "Waiting 5 seconds before continuing... [ctrl + c] to exit if needed"
  sleep 5;
  #~ continue_pause;
}

smart_check() {
  local sdrive="$@";
  local id=$(smart_get_id $sdrive)
  [ -z "$id" ] && id="${sdrive%% *}";
  echo "Checking $id";
  $SMARTCTL -a $dr|grep SMART|grep 'self-assessment'
  $SMARTCTL -cl selftest $sdrive|\
        grep -EA1 -B1 'Self-test execution|^#\s+[0-3]'|\
        grep -v Offline
}

continue_pause() {
  local y=;
  echo "Press [Enter] to continue or [ctrl + c] to exit";
  read y;
}
