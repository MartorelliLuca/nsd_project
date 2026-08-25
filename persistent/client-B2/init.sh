#!/bin/sh

ip addr add 192.168.95.2/24 dev eth0
ip link set eth0 up
ip route add default via 192.168.95.1