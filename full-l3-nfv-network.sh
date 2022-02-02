#!/bin/bash

# create an OvS bridge called ovs-earth
ovs-vsctl add-br ovs-earth

# create network namespaces
ip netns add mar
ip netns add car
ip netns add tar
ip netns add par

# create ovs-earth bridge internal interfaces for network namespaces
ovs-vsctl add-port ovs-earth mar -- set interface mar type=internal
ovs-vsctl add-port ovs-earth car -- set interface car type=internal
ovs-vsctl add-port ovs-earth tar -- set interface tar type=internal
ovs-vsctl add-port ovs-earth par -- set interface par type=internal

# connect the ovs-earth bridge internals into the network namespaces
ip link set mar netns mar
ip link set car netns car
ip link set tar netns tar
ip link set par netns par

# bring interfaces UP in network namespaces
ip netns exec mar ip link set dev mar up
ip netns exec mar ip link set dev lo up
ip netns exec car ip link set dev car up
ip netns exec car ip link set dev lo up
ip netns exec tar ip link set dev tar up
ip netns exec tar ip link set dev lo up
ip netns exec par ip link set dev par up
ip netns exec par ip link set dev lo up

# add IP addresses to network namespace ovs-earth interfaces
ip netns exec mar ip addr add 10.64.10.2/24 dev mar
ip netns exec car ip addr add 10.64.10.3/24 dev car
ip netns exec tar ip addr add 10.64.11.2/24 dev tar
ip netns exec par ip addr add 10.64.11.3/24 dev par

# Remove auto-add routes from network namespaces
ip netns exec mar ip route del 10.64.10.0/24
ip netns exec car ip route del 10.64.10.0/24
ip netns exec tar ip route del 10.64.11.0/24
ip netns exec par ip route del 10.64.11.0/24

# Add default routes to network namespaces
ip netns exec tar ip route add default via 10.64.11.1 dev tar onlink
ip netns exec par ip route add default via 10.64.11.1 dev par onlink
ip netns exec car ip route add default via 10.64.10.1 dev car onlink
ip netns exec mar ip route add default via 10.64.10.1 dev mar onlink

# add VLAN tags to network namespaces ovs-earth interfaces
ovs-vsctl set port mar tag=2
ovs-vsctl set port car tag=2
ovs-vsctl set port tar tag=90
ovs-vsctl set port par tag=90

# Create the NFV Router
ip netns add router

# Create ovs-earth bridge internal interfaces for router and connect
ovs-vsctl add-port ovs-earth router1 -- set interface router1 type=internal
ip link set router1 netns router
ovs-vsctl add-port ovs-earth router2 -- set interface router2 type=internal
ip link set router2 netns router

# Bring up loopback and ovs-earth interfaces in router
ip netns exec router ip link set dev router1 up
ip netns exec router ip link set dev router2 up
ip netns exec router ip link set dev lo up

# Add IP addresses to router ovs-earth interfaces and replace auto-add routes
ip netns exec router ip addr add 10.64.10.1/24 dev router1
ip netns exec router ip route del 10.64.10.0/24
ip netns exec router ip route add 10.64.10.0/24 dev router1
ip netns exec router ip addr add 10.64.11.1/24 dev router2
ip netns exec router ip route del 10.64.11.0/24
ip netns exec router ip route add 10.64.11.0/24 dev router2

# Add VLAN tags to router ovs-earth interfaces
ovs-vsctl set port router1 tag=2
ovs-vsctl set port router2 tag=90

# Enable packet forwarding in router namespace
cat << EOF >  10-ip-forwarding.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.forwarding = 1
EOF
cp 10-ip-forwarding.conf /etc/sysctl.d/10-ip-forwarding.conf
rm 10-ip-forwarding.conf
ip netns exec router sysctl -p /etc/sysctl.d/10-ip-forwarding.conf

# Create veth to connect router to the root namespace
ip link add host2router type veth peer name router2host
ip link set dev router2host netns router

# Bring up router veth interface to root
ip netns exec router ip link set dev router2host up

# Bring up root veth interface to router
ip link set dev host2router up

# Add IP address to router veth interface to root and delete auto-add route
ip netns exec router ip addr add 10.64.4.2/24 dev router2host
ip netns exec router ip route del 10.64.4.0/24

# Add default route to router namespace
ip netns exec router ip route add default dev router2host via 10.64.4.1 onlink

# Add IP address to root veth interface to router
ip addr add 10.64.4.1/24 dev host2router
ip route del 10.64.4.0/24
ip route add 10.64.4.0/24 dev host2router

# Add summary 10.64/20 route to root namespace pointing to router namespace
ip route add 10.64.0.0/20 via 10.64.4.2 dev host2router onlink

# Add router namespace iptables NAT
# ip netns exec router iptables -t nat -A POSTROUTING -j MASQUERADE

# Add root namespace iptables 10.64/20 <--> ens3 interface IP NAT to root namespace
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -P FORWARD DROP && iptables -F FORWARD
iptables -t nat -F
iptables -t nat -A POSTROUTING -s 10.64.0.0/20 -o ens3 -j MASQUERADE
iptables -A FORWARD -i ens3 -o host2router -j ACCEPT
iptables -A FORWARD -o ens3 -i host2router -j ACCEPT

# Add root namespace iptables destination NAT for ens3:5555 to 10.64.10.2:9999
iptables -t nat -A PREROUTING -i ens3 -p tcp -m tcp --dport 8080 -j DNAT --to-destination 10.64.10.2:80
iptables -A FORWARD -p tcp -d 10.64.10.2 --dport 80 -j ACCEPT

