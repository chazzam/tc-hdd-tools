#!/bin/sh

packetloss_stats() {
  local total="$(wc -l $1|\
    cut -d\  -f1|\
    tr [:space:] ':'|\
    sed 's/:/00/')"

  local loss="$(expr $(grep -v 0% $1 |\
    cut -d, -f3|\
    grep loss|\
    sed -e 's/[^0-9]//g'|\
    tr '\n' '+'|\
    sed -e 's/+$//;s/+/ + /g;'))"
  
  # Catch pings that fail to return anything at all
  local additional_loss="$(expr $(grep -v 0% $1 |\
    cut -d, -f3|\
    grep -v loss|\
    wc -l))";

  #loss="$(expr $additional_loss \* 100 + $loss)";
  loss="$(expr $additional_loss + $loss)";
  local percent=$(echo "scale=15;$loss/$total"|bc);
  echo "$loss/$total = $percent";
}

if [ "$1" == "" ]; then
  echo "Must specify a log file"
  exit 1
fi

if [ "$(which bc)" == "" ]; then
  sudo -u tc tce-load -wi bc-1.06.94
fi

packetloss_stats $1
