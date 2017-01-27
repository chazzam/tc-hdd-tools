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
L_SHRED="$LOG_DIR/shred"
L_NETWORK_STATS="$LOG_DIR/network-stats.log"
L_NETWORK="$LOG_DIR/network.log"
L_LCD="$LOG_DIR/lcd.log"
L_HDPARM="$LOG_DIR/hdparm"
L_CARDS="$LOG_DIR/cards.lst"
L_SYSTEM="$LOG_DIR/system.log"
SHRED_RUN=""
HDPARM="/usr/local/sbin/hdparm"

exerr() {
  local msg="$1"
  shift
  printf "\n\n$msg\n" $@
  echo;
  exit 1
}

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

detect_cards() {
  # RAID:: Threeware 13c1:* ; Adaptec 9005:* ; LSI 1000:* ;
  # Digium Cards: d161:*
  # Digium PCI-E Active Riser: 111d:806e
  local cards="$(lspci -n|egrep '((d161|13c1|9005|1000):|111d:806e)'|wc -l)"
  (
    printf "\nDetected %s cards:\n" $cards
    lspci -nn|egrep '((d161|13c1|9005|1000):|111d:806e)'
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
  printf "\n\nStore Case/RMA Number?\n[Yn]: "
  read y;
  [ "$y" = "n" -o "$y" = "N" ] && return
  printf "\nEnter Case/RMA Number: "
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

continue_pause() {
  local y=;
  echo "Press [Enter] to continue or [ctrl + c] to exit";
  read y;
}



# S.M.A.R.T. utility functions
identify_drives() {
  printf "\nChecking drive statuses...\n"
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
  [ -z "${ALL_SMART[0]}" ] && identify_drives;
  for dr in "${ALL_SMART[@]}"; do
    smart_init "$dr";
  done;
  [ -z "$TESTS" ] && TESTS="short conveyance long"
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
  $SMARTCTL -Hl selftest $sdrive >> $L_SMART 2>&1
  log="$($SMARTCTL -l selftest $sdrive|grep ^#|sed -e 's/\s\s\+/,/g;'|
    grep -i $stest|head -n1)"
  if [ -z "$log" -a "$stest" = "Conveyance" ]; then
    # conveyance isnt always supported
    echo 1
    return
  elif [ -z "$log" -a ! -z "$($SMARTCTL -l selftest $sdrive|grep -o 'Log not supported')" ]; then
    # no logs for this drive..., so... check that it never detected an error?
    log="C$($SMARTCTL -a $sdrive|
      grep -A2 'Self-test execution status'|
      tr '\n' ' '|
      sed 's/\s\s\+/ /g'|
      grep -o 'ompleted without error')"
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

smart_status_all() {
  local dr=""
  local status=""
  [ -z "${ALL_SMART[0]}" ] && identify_drives;
  for dr in "${ALL_SMART[@]}"; do
    [ -z "$status" ] && status="1"
    status=$(($status & $(smart_status $dr)))
  done
  [ -z "$status" ] && status="0"
  echo $status
}

smart_shred() {
  # If smart fails, run shred, then run smart again
  [ -z "${ALL_SMART[0]}" ] && identify_drives;
  smart_process || exerr "Smart failed to run";
  if [ "$(smart_status_all)" != "1" ]; then
    call_shred "super-long";
    smart_process || exerr "Smart failed to run";
  fi
}



# HDPARM timing functions
install_bc() {
  [ -z "$(which bc)" ] || return 0
  # Run tce-load in a subshell so it won't exit this script
  (
    sudo -u tc tce-load -wi bc ||
    sudo -u tc tce-load -wi bc-1.06.94
  ) ||
    echo "ERROR: 'bc' unavailable" && exit 1
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
  ( install_bc );
  for dr in $SDXS; do
    dr="${dr%% *}"
    d="$dr"
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



# Tarball functions
name_tarball() {
  local tarball="tools-logs"
  [ -r "$L_SYSTEM" ] || touch "$L_SYSTEM"
  . "${L_SYSTEM}"
  [ ! -z "$RMA" ] && tarball="${tarball}_${RMA// /-}"
  [ ! -z "$SERIAL" ] && tarball="${tarball}_${SERIAL// /-}"
  printf "%s.tar.gz" "$tarball"
}



# SSD & Security-Erase/shred functions
install_hdparm() {
  # Need the real hdparm, not the busybox version
  local path=""
  path=$(readlink -f $(which hdparm)|grep -o busybox)
  [ -z "$path" ] && return 0
  # Run tce-load in a subshell so it won't exit this script
  (sudo -u tc tce-load -wi hdparm) ||
    echo "ERROR: 'hdparm' unavailable" && exit 1
}

is_ssd() {
  local sdrive="$@";
  local rotation="";
  rotation="$($SMARTCTL -i $sdrive|
    grep 'Rotation Rate'|
    sed 's/\s\s\+/,/g'|
    cut -d, -f2)"
  #~ rotation="$(hdparm -I $sdrive|
    #~ grep 'Rotation Rate'|
    #~ cut -d: -f2)"
  rotation="$(echo $rotation)" #trim
  [ "$rotation" = "Solid State Device" ] && rotation="1" || rotation="0"
  printf "%s" "$rotation"
}

all_ssd() {
  local dr=""
  local status=""
  #~ [ -z "$SDXS" ] && list_disks
  [ -z "${ALL_SMART[@]}" ] && identify_drives >&2;
  for dr in "${ALL_SMART[@]}"; do
  #~ for dr in $SDXS; do
    [ -z "$status" ] && status="1"
    status=$(($status & $(is_ssd $dr)))
  done
  [ -z "$status" ] && status="0"
  printf "%s" "$status"
}

any_ssd() {
  local dr=""
  local status=""
  #~ [ -z "$SDXS" ] && list_disks
  [ -z "${ALL_SMART[@]}" ] && identify_drives >&2;
  for dr in "${ALL_SMART[@]}"; do
  #~ for dr in $SDXS; do
    [ -z "$status" ] && status="0"
    status=$(($status | $(is_ssd $dr)))
  done
  [ -z "$status" ] && status="0"
  printf "%s" "$status"
}

call_shred() {
  if [ "$(any_ssd)" = "1" ]; then
    # log to shred log that this is ssd and we won't shred
    printf "\n\nSSDs detected, skipping shred. Run Security Erase instead\n\n"|
      tee -a L_SHRED
    return 0
  fi
  local shred_args="$@"
  [ -z "$shred_args" ] && shred_args="long"
  shred-all $shred_args auto || exerr "Couldn't run shred or shred failed"
  SHRED_RUN="1"
}

thaw_drives() {
  local status="0";local dr="";local line=""
  [ -z "$SDXS" ] && exerr "ERROR: Must run entire walkthrough"
  for dr in $SDXS; do
    #~ [ "$(is_ssd $dr)" = "1" ] || continue
    line="$($HDPARM -I $dr 2>&1|grep frozen)"
    if [ -z "$line" ]; then
      exerr "ERROR: Drive %s could not be read\nPower off and ensure connected directly to motherboard." "$dr"
    fi
    line="$(echo $line)" # trim
    if [ "$line" = "frozen" ]; then
      # Security still enabled, suspend drive and flag needing pulled
      printf "Drive %s is frozen\n" "$dr"
      $HDPARM -qY $dr 2>&1
      line="1"
    else
      printf "Drive %s is ready\n" "$dr"
      line="0"
    fi
    status=$(( $status | $line ))
  done;
  if [ "$status" = "1" ]; then
    printf "\n\nDisconnect drives from power/sata and re-insert\n\n"
    continue_pause;
  fi
  return $status
}

set_drive_password() {
  local dr="$1"
  [ -z "$dr" ] && exerr "ERROR: Must specify drive"
  #~ [ "$(is_ssd $dr)" = "1" ] || return
  SSD_PASSWORD="Password"
  $HDPARM --user-master u --security-set-pass $SSD_PASSWORD $dr >/dev/null 2>&1 || \
    exerr "Couldn't set password for Drive $dr"
  local line=""
  line="$($HDPARM -I $dr 2>&1|grep -A5 Security:|grep enabled)"
  line="$(echo $line)"
  [ -z "$line" ] && \
    exerr "ERROR unknown failure on setting password on $dr"
  [ "$line" = "enabled" ] || \
    exerr "ERROR: Failed to set password on $dr"
}

erase_drives() {
  [ -z "$SDXS" ] && exerr "ERROR: Must run entire walkthrough"
  local erase="$1"
  [ -z "$erase" ] && erase="erase" || erase="erase-enhanced"
  local line="";local dr=""
  for dr in $SDXS; do
    #~ [ "$(is_ssd $dr)" = "1" ] || continue
    # Check if enhanced erase supported, skip enhanced erase if not
    line="$($HDPARM -I $dr 2>&1|grep -A9 Security:|grep enhanced|grep -o not)"
    [ "not" = "$line" -a "$erase" = "erase-enhanced" ] &&\
      printf "\n\nDrive %s: Enhanced Erase not supported, skipping\n" "$dr" &&\
      continue
    printf "\n\nDrive %s: Running security-%s\n" "${dr##/dev/}" "$erase"
    # Set the security password on the drive
    set_drive_password $dr
    # Perform the erase
    $HDPARM --user-master u --security-${erase} $SSD_PASSWORD $dr 2>&1|| \
      exerr "Couldn't $erase Drive $dr"
    # Verify it succeeded (security 'not enabled')
    line="$($HDPARM -I $dr 2>&1|grep -A5 Security:|grep enabled)"
    line="$(echo $line)"
    [ "$line" = "enabled" ] && \
      exerr "ERROR ${dr##/dev/} Security-${erase} failed"
  done;
}

security_erase_walkthrough() {
  [ -z "$SDXS" ] && list_disks
  [ -z "$SDXS" ] && exerr "ERROR: No drives found to work with"
  [ "$(any_ssd)" = "1" ] || exerr "ERROR: No SSD drives detected"

  ( install_hdparm );
  cat<<EOF

Please ensure only SSD drives are installed, and that every drive
is connected directly to the motherboard. Neither Security erase nor
firmware upgrades can be performed while the drive is connected via
a RAID card.

If any drives are still connected via a RAID card, power off and correct
this before continuing.

WARNING!!! WARNING!!! WARNING!!! TAKE HEED!!! WARNING!!!
This operation will wipe the contents and file system of the
confirmed drives. This operation is intended to be unrecoverable.
Ensure you have good working backups of any important data.
We will not be held liable for any lost data as a result of this process
WARNING!!! WARNING!!! WARNING!!! TAKE HEED!!! WARNING!!!

EOF

  continue_pause
  # We want to run thaw_drives at least twice probably
  # Once to inform them to pull the drives, then again to verify thawing
  local count=0
  while [ "$count" -le 4 ]; do
    thaw_drives && break || count=$(expr $count + 1);
  done
  (
    printf "\n\nTrying Security Erase on all drives...\n"
    erase_drives;
    printf "\n\nTrying Enhanced Security Erase on all drives...\n"
    erase_drives "enhanced";
    printf "\n\n"
  )| tee -a $L_SHRED
}
