#!/usr/bin/env bash

header_info() {
  clear
  cat <<"EOF"
   _____            __                             _ _             
  / ____|          / _|                      /\   | | |            
 | |  __ _ __ __ _| |_ __ _ _ __   __ _     /  \  | | | ___  _   _ 
 | | |_ | '__/ _` |  _/ _` | '_ \ / _` |   / /\ \ | | |/ _ \| | | |
 | |__| | | | (_| | || (_| | | | | (_| |  / ____ \| | | (_) | |_| |
  \_____|_|  \__,_|_| \__,_|_| |_|\__,_| /_/    \_\_|_|\___/ \__, |
                                                              __/ |
                                                             |___/ 
EOF
}

RD=$(echo "\033[01;31m")
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD="-"
CM="${GN}✓${CL}"
CROSS="${RD}✗${CL}"

set -euo pipefail
shopt -s inherit_errexit nullglob

msg_info() {
  local msg="$1"
  echo -ne " ${HOLD} ${YW}${msg}..."
}

msg_ok() {
  local msg="$1"
  echo -e "${BFR} ${CM} ${GN}${msg}${CL}"
}

msg_error() {
  local msg="$1"
  echo -e "${BFR} ${CROSS} ${RD}${msg}${CL}"
}

get_pve_version() {
  local pve_ver
  pve_ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  echo "$pve_ver"
}

get_pve_major_minor() {
  local ver="$1"
  local major minor
  IFS='.' read -r major minor _ <<<"$ver"
  echo "$major $minor"
}

main() {
  header_info
  echo -e "\nThis script will Install Grafana Alloy to collect Open Telemetry Data.\n"
  while true; do
    read -p "Start the Grafana Alloy Install Script (y/n)? " yn
    case $yn in
    [Yy]*) break ;;
    [Nn]*)
      clear
      exit
      ;;
    *) echo "Please answer yes or no." ;;
    esac
  done

  local PVE_VERSION PVE_MAJOR PVE_MINOR
  PVE_VERSION="$(get_pve_version)"
  read -r PVE_MAJOR PVE_MINOR <<<"$(get_pve_major_minor "$PVE_VERSION")"

  if [[ "$PVE_MAJOR" == "9" ]]; then
    if ((PVE_MINOR != 0)); then
      msg_error "Only Proxmox 9.0 is currently supported"
      exit 1
    fi
    start_routines_9
  else
    msg_error "Unsupported Proxmox VE major version: $PVE_MAJOR"
    echo -e "Supported: 9.0"
    exit 1
  fi
}

start_routines_9() {
  header_info
}

main()
