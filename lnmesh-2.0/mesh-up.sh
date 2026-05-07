#!/bin/bash
# IBSS (ad-hoc) on wlan0. Run as root.
# Usage: sudo bash mesh-up.sh <ip/cidr>   e.g.  sudo bash mesh-up.sh 10.0.0.1/24

set -e
IP=$1

cat > /etc/NetworkManager/conf.d/99-mesh.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
systemctl reload NetworkManager
sleep 1

ip link set wlan0 down
iw dev wlan0 set type ibss
ip link set wlan0 up
iw dev wlan0 ibss join lnmesh 2412
ip addr add "$IP" dev wlan0
