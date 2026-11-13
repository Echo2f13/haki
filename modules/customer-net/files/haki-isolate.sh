#!/bin/bash
# Proxmox hookscript (installed by: haki install customer-net). Isolates customer containers from
# each other: isolated bridge ports can reach the gateway (the host) but not other isolated ports.
vmid=$1 phase=$2
if [[ $phase == post-start ]]; then
  for dev in /sys/class/net/veth"${vmid}"i*; do
    [[ -e $dev ]] && bridge link set dev "$(basename "$dev")" isolated on
  done
fi
exit 0
