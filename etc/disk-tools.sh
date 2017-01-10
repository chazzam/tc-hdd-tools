#!/bin/bash
# Written by Charles Moye cmoye@digium.com
# Copyright 2012-2017 Charles Moye
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
LOG_DIR="/tmp/tools-logs"
[ -d $LOG_DIR ] || mkdir -p $LOG_DIR
L_SMART="$LOG_DIR/smart.log"
L_DRIVES="$LOG_DIR/drives.lst"
L_SHRED="$LOG_DIR/shred.log"
L_NETWORK_STATS="$LOG_DIR/network-stats.log"
L_NETWORK="$LOG_DIR/network.log"
L_LCD="$LOG_DIR/lcd.log"
L_HDPARM="$LOG_DIR/hdparm"
L_CARDS="$LOG_DIR/cards.lst"
L_SYSTEM="$LOG_DIR/system.log"

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
  echo "smart,smart_id,conveyance" > $L_DRIVES;

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
    echo "${ALL_SMART[i]},${ALL_SMART_ID[i]},${ALL_CONVEYANCE[i]}" >> $L_DRIVES
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

#L_SMART
smart_init() {
  checkroot;
  local sdrive="$@";
  local id=$(smart_get_id $sdrive)
  [ -z "$id" ] && id="${sdrive%% *}";

  local vol="$(echo $sdrive|cut -d\  -f1)";
  local args="$(echo $sdrive|cut -d\  -f2-)";
  (
    #echo -e "\n===============================================================================";
    echo "Initiating $id using $sdrive";
    $SMARTCTL -i $sdrive 2>&1|\
        grep -E 'Model Family:|Device Model:|Serial Number:|User Capacity:';
    $SMARTCTL -s on -S on -o on $sdrive 2>&1|grep SMART;
    #$SMARTCTL -c $sdrive;
    $SMARTCTL -H $sdrive 2>&1|grep "test result";
    echo -e "===============================================================================\n";
  ) | tee -a $L_SMART
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
  echo "Test:$stest on ${id} should take about ${SMART_TIME## }."|tee -a $L_SMART
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
        echo "Conveyance test not supported on $id"|tee -a $L_SMART
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
  (
    echo "Checking $id";
    $SMARTCTL -a $sdrive|grep SMART|grep 'self-assessment'
    $SMARTCTL -cl selftest $sdrive|\
          grep -EA1 -B1 'Self-test execution|^#\s+[0-3]'|\
          grep -v Offline
  )|tee -a $L_SMART
}

smart_status_log() {
  local stest="$1"
  shift
  local sdrive="$@"
  local log=""
  local output="0"
  $SMARTCTL -Hl selftest $sdrive 2>&1 >> $L_SMART
  log="$($SMARTCTL -l selftest $sdrive|grep ^#|sed -e 's/\s\s\+/,/g;'|
    grep -i $stest|head -n1)"
  if [ -z "$log" -a "$stest" = "Conveyance" ]; then
    # conveyance isnt always supported
    echo 1
    return
  fi
  [ "$(echo $log|cut -d, -f3)" = "Completed without error" ] && \
    output="1"
  echo $output
}

smart_status() {
  local sdrive="$@";
  local overall="0"
  local short="0"
  local conveyance="1"
  local long="0"
  overall="$($SMARTCTL -H $sdrive|grep SMART|grep 'self-assessment'|
    grep -o ': ....'|cut -d\  -f2)"
  [ "$overall" = "PASS" ] && overall=1 || overall="0"
  short="$(smart_status_log Short $sdrive)"
  conveyance="$(smart_status_log Conveyance $sdrive)"
  long="$(smart_status_log Extended $sdrive)"
  echo $(( $overall & $short & $conveyance & $long ))
}

continue_pause() {
  local y=;
  echo "Press [Enter] to continue or [ctrl + c] to exit";
  read y;
}

install_bc() {
  if [ "$(which bc)" == "" ]; then
    (sudo -u tc tce-load -wi bc ||
      sudo -u tc tce-load -wi bc-1.06.94) ||
      echo "ERROR: 'bc' unavailable" && exit 1
  fi
}

thousands() {
  echo "$@"|sed -re ' :restart ; s/([0-9])([0-9]{3})($|[^0-9])/\1,\2\3/ ; t restart '
}

hdparm_stat() {
  local line="$1" # cache or disk
  local f="$2" # file
  local base=""
  local unit=""
  local avg=""
  local count=0
  base="$(grep $line $f|cut -d= -f2)"
  unit="$(echo $base|cut -d\  -f2)"
  count="$(echo $base|grep -o \/s|wc -l)"
  avg="$(echo $base|sed -e 's# [A-Za-z/]\+##g;s/ / + /g;')"
  avg=$(printf "scale=2;( %s ) / %s\n" "$avg" "$count"|bc)
  printf "%s %s" "$(thousands $avg)" "$unit"
}

run_hdparm() {
  local dr="";local d=""
  local logfile="$(basename $L_HDPARM)"
  [ -z "$SDXS" ] && list_disks
  #[ -z "$LVM_VOLS" ] && list_lvm
  ( install_bc );
  #for dr in $SDXS $LVM_VOLS; do
  for dr in $SDXS; do
    dr="${dr%% *}"
    d="$dr"
    #d="$(readlink -f $d)"
    d="${d##/dev/}"
    d="${d##mapper/}"
    d="${d##VolGroup*/}"
    d="${d##*/}"
    hdparm -tT $dr $dr $dr|tee -a "${L_HDPARM}-vol-$d.log"
  done;
  printf "\n\n"
  for dr in $(find $LOG_DIR -name "${logfile}-vol*"); do
    dr="$dr"
    printf \
      "Average Reads %s:: disk: %s cached: %s\n" \
      "$(basename -s .log ${dr/${logfile}-vol-/})" \
      "$(hdparm_stat disk $dr)" \
      "$(hdparm_stat cache $dr)" \
    | tee -a "${L_HDPARM}-stats.log"
  done;
}

detect_cards() {
  local cards="$(lspci -nn -d d161:*|wc -l)"
  (
    printf "\nDetected %s cards:\n" $cards
    lspci -nn -d d161:*
  ) | tee -a $L_CARDS
}

prompt_lcd() {
  # Run LCD Test?
  # if yes, log and direct
  # Press X, (Check), Down, Left, Right, Up
  # verify that the screen updates correspondingly, and that the Backlight adjusts
  printf "\n\nRun LCD Test?\n[Yn]: "
  local y=;
  read y;
  [ "$y" = "n" -o "$y" = "N" ] && return
  (
    cat<<EOF
To Test the LCD, Press the keys below, in the order listed.
Verify that the Front Panel LCD screen updates correspondingly, and that
the Backlight changes.

Press:
X, (Check), Down, Left, Right, Up

Did the LCD update properly? [yN]: 
EOF
  read y
  if [ "$y" = "y" -o "$y" = "Y" ]; then
    printf "This shall be logged as LCD Test PASSed\n"
  else
    printf "This shall be logged as LCD Test FAILed\n"
  fi
  ) | tee -a $L_LCD
  # get results: egrep -o 'LCD Test ....' $L_LCD|tail -n1|cut -d\  -f3|tr '[:lower:]' '[:upper:]'
  # leaves you with either 'PASS' or 'FAIL'
}

load_cmdline() {
  local arg=""
  for arg in $(cat /proc/cmdline); do
      echo $arg | grep -iq "TESTER-";
      if [ "$?" = "0" ]; then
          export $(echo $arg | cut -d- -f2);
      fi;
  done
}

prompt_system() {
  local y=;
  printf "\n\nStore RMA-Number?\n[Yn]: "
  read y;
  [ "$y" = "n" -o "$y" = "N" ] && return
  printf "\nEnter RMA-Number: "
  local rma=
  read rma;
  printf "\n\nStore Serial Number?\n[Yn]: "
  read y;
  local sn="."
  if [ "$y" != "n" -a "$y" != "N" ]; then
    printf "\nEnter Serial Number: "
    read sn;
  fi
  printf "\n\n"
  printf "RMA=%s\nSERIAL=%s\n" "$rma" "$sn"| tee -a "$L_SYSTEM"
}
