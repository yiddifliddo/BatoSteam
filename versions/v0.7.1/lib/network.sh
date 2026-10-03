#!/bin/bash
# BatoSteam Installer - network check and Wi-Fi connect
# Author: Dan Lee
# Version: 0.7.1
#
# BatoSteam uses whatever network the live system has (Ethernet, Wi-Fi, USB tethering).
# Before an install it works out which servers are needed for the chosen plan, checks
# they can be reached, and if not offers to connect to Wi-Fi (NetworkManager / nmcli),
# retry, or cancel - before anything is written.
# Wi-Fi passwords are never written to the log.

NET_HOST_BATOCERA="https://updates.batocera.org/installs.txt"
NET_HOST_REFIND="https://sourceforge.net/projects/refind/"

# One line per network interface: NAME<TAB>TYPE<TAB>STATE
net_interfaces() {
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -vE ':(loopback|bridge|tun|wifi-p2p):' | tr ':' '\t'
    return 0
  fi
  local i type state
  for i in /sys/class/net/*; do
    i="$(basename "$i")"; [[ $i = lo ]] && continue
    type=ethernet; [[ -d /sys/class/net/$i/wireless ]] && type=wifi
    state="$(cat "/sys/class/net/$i/operstate" 2>/dev/null)"
    printf '%s\t%s\t%s\n' "$i" "$type" "${state:-unknown}"
  done
}

# Human readable status for the menus.
net_status_text() {
  local s="" name type state
  while IFS=$'\t' read -r name type state; do
    case $type in
      ethernet) s+="  Ethernet  $name: $state\n" ;;
      wifi)     s+="  Wi-Fi     $name: $state$(net_wifi_ssid "$name")\n" ;;
      gsm|bt)   s+="  Mobile    $name: $state\n" ;;
      *)        s+="  $type $name: $state\n" ;;
    esac
  done < <(net_interfaces)
  [[ -n $s ]] || s="  No network adapters found.\n"
  [[ $(net_interfaces | awk -F'\t' '$2=="wifi"' | wc -l) -eq 0 ]] && \
    s+="  (No Wi-Fi adapter detected - use an Ethernet cable or phone USB tethering.)\n"
  echo "$s"
}

net_wifi_ssid() {
  command -v nmcli >/dev/null 2>&1 || return 0
  local ssid
  ssid="$(nmcli -t -f GENERAL.CONNECTION device show "$1" 2>/dev/null | cut -d: -f2-)"
  [[ -n $ssid && $ssid != "--" ]] && echo " ($ssid)"
}

# True if the URL answers within a few seconds.
net_reachable() { curl -fsSIL --max-time 15 -o /dev/null "$1" 2>/dev/null; }

# Which servers does the current plan need? Prints "NAME<TAB>URL" lines.
# Uses the installer's choice variables (BATO_MODE, STEAM_MODE, STEAMOS_IMAGE, ...).
net_needed_hosts() {
  if [[ -n ${BATO_DISK:-} && ${BATO_MODE:-} = wipe && -z ${BATOCERA_IMAGE:-} && -z ${BATO_OFFLINE:-} ]]; then
    printf 'Batocera download (updates.batocera.org)\t%s\n' "$NET_HOST_BATOCERA"
  fi
  if [[ -n ${BATO_DISK:-} && ${BATO_MODE:-} = keep ]]; then
    printf 'Batocera repair files (updates.batocera.org)\t%s\n' "$NET_HOST_BATOCERA"
  fi
  # Valve's server only answers for real files, so the exact image URL is checked
  if [[ -n ${STEAM_DISK:-} && ${STEAM_MODE:-} != leave && ${STEAMOS_IMAGE:-} = http* ]]; then
    printf 'SteamOS download (Valve)\t%s\n' "$STEAMOS_IMAGE"
  fi
  if [[ -z $(refind_offline_zip) ]]; then
    printf 'Boot menu - rEFInd (sourceforge.net)\t%s\n' "$NET_HOST_REFIND"
  fi
}

# Connect to a Wi-Fi network with NetworkManager.
net_wifi_connect() {
  if ! command -v nmcli >/dev/null 2>&1; then
    ui_msg "Wi-Fi" "This live system has no NetworkManager command-line tool (nmcli).\n\nConnect with the network icon in the taskbar (bottom-right of the desktop), then choose 'Check again'."
    return 1
  fi
  if [[ $(net_interfaces | awk -F'\t' '$2=="wifi"' | wc -l) -eq 0 ]]; then
    ui_msg "Wi-Fi" "No Wi-Fi adapter was found on this PC (or the recovery system has no driver for it).\n\nUse an Ethernet cable or phone USB tethering instead."
    return 1
  fi
  nmcli radio wifi on >/dev/null 2>&1
  log "Scanning for Wi-Fi networks"
  nmcli device wifi rescan >/dev/null 2>&1; sleep 3
  local args=() ssids=() ssid signal security choice pw hidden=0 n=0
  # nmcli -t escapes ':' inside a name as '\:' - turn the list into TAB-separated lines first
  while IFS=$'\t' read -r ssid signal security; do
    [[ -z $ssid ]] && continue
    [[ " ${ssids[*]} " = *" $ssid "* ]] && continue      # strongest entry per name only
    n=$((n + 1)); ssids+=("$ssid")
    args+=("$n" "$ssid   (signal ${signal}%, ${security:-open})")
  done < <(nmcli -t -f SSID,SIGNAL,SECURITY device wifi list 2>/dev/null \
             | sed -e 's/\\:/\x01/g' -e 's/:/\t/g' -e 's/\x01/:/g' | sort -t$'\t' -k2 -nr)
  args+=("h" "Hidden network (type the name)")
  choice="$(ui_menu "Wi-Fi networks" "Choose your Wi-Fi network:" "${args[@]}")" || return 1
  if [[ $choice = h ]]; then
    hidden=1
    choice="$(ui_input "Hidden network" "Wi-Fi network name (SSID):" "")" || return 1
    [[ -n $choice ]] || return 1
  else
    choice="${ssids[$((choice - 1))]}"
  fi
  pw="$(ui_password "Wi-Fi password" "Password for '$choice' (leave empty for an open network):")" || return 1
  log "Connecting to Wi-Fi '$choice'"            # the password is never logged
  ui_msg "Connecting" "Connecting to '$choice'... this can take up to 30 seconds after you press Enter."
  local out extra=()
  [[ $hidden = 1 ]] && extra=(hidden yes)
  [[ -n $pw ]] && extra+=(password "$pw")
  out="$(nmcli --wait 30 device wifi connect "$choice" "${extra[@]}" 2>&1)"
  local rc=$?
  pw=""; extra=()
  if [[ $rc -ne 0 ]]; then
    log "Wi-Fi connect failed: ${out//$'\n'/ }"
    ui_msg "Wi-Fi failed" "Could not connect to '$choice':\n${out}\n\nCheck the password and try again."
    return 1
  fi
  log "Wi-Fi connected to '$choice'"
}

# Status screen + connect menu (main-menu item).
net_menu() {
  local choice
  while true; do
    choice="$(ui_menu "Network" "Current network:\n$(net_status_text)\nInternet: $(net_reachable "$NET_HOST_BATOCERA" && echo 'OK' || echo 'NOT reachable')" \
      refresh "Check again" \
      wifi    "Connect to Wi-Fi" \
      back    "Back")" || return 0
    case $choice in
      wifi) net_wifi_connect ;;
      back) return 0 ;;
    esac
  done
}

# Before an install: make sure every server the plan needs can be reached.
# Returns 1 if the user cancels (nothing has been written at this point).
net_preflight() {
  local needed name url missing choice
  needed="$(net_needed_hosts)"
  if [[ -z $needed ]]; then
    log "Network: this install needs no downloads (fully offline)"
    return 0
  fi
  while true; do
    missing=""
    while IFS=$'\t' read -r name url; do
      [[ -z $name ]] && continue
      if [[ $DRY_RUN = 1 && ${NET_SKIP_CHECK:-0} = 1 ]] || net_reachable "$url"; then
        log "Network: OK - $name"
      else
        log "Network: NOT reachable - $name"
        missing+="  * $name\n"
      fi
    done <<< "$needed"
    [[ -z $missing ]] && return 0
    choice="$(ui_menu "No internet connection" \
"This install needs to download:\n$missing\nCurrent network:\n$(net_status_text)\nNothing has been written to any drive yet." \
      retry  "Check again (e.g. after plugging in an Ethernet cable)" \
      wifi   "Connect to Wi-Fi" \
      cancel "Cancel - go back")" || return 1
    case $choice in
      wifi)   net_wifi_connect ;;
      cancel) return 1 ;;
    esac
  done
}
