#!/bin/sh

set -o errexit
set -x
1>&-
exec 1>/var/log/nova-setup.sh.log
exec 2>&1

if [ -f /root/keystonerc_admin ]; then
    . /root/keystonerc_admin
elif [ -f /root/adminrc ]; then
    . /root/adminrc
fi

network_gw_ip=`ip route show | awk '/^default/ {print $3}'`

#ifdown eth0
#ifdown br-ex
#ifup br-ex
#ifup eth0
systemctl restart network.service

# restart nova and neutron and networking
openstack-service restart nova
openstack-service restart neutron

USE_PROVIDER_NETWORK=1
if [ -n "$USE_PROVIDER_NETWORK" ] ; then
    pubnet=public
    privnet=private
    neutron net-create $pubnet --provider:network_type flat --provider:physical_network extnet \
            --router:external --shared
    neutron subnet-create --name public_subnet --enable_dhcp=False \
            --allocation-pool=start={{ ansible_eth0.ipv4.address.rsplit('.', 1)[0] + '.128' }},end={{ ansible_eth0.ipv4.address.rsplit('.', 1)[0] + '.254' }} \
            --dns-nameserver {{ nameserver }} --dns-nameserver {{ ipa_forwarder }} \
            --gateway=$network_gw_ip \
             public {{ ansible_eth0.ipv4.address + '/24' }}
    neutron router-create router1
    neutron net-create $privnet
    neutron subnet-create --name private_subnet $privnet 10.0.0.0/24
    neutron router-interface-add router1 private_subnet
    neutron net-show $pubnet
    neutron net-show $privnet
    neutron subnet-show public_subnet
    neutron subnet-show private_subnet
    neutron port-list --long
    neutron router-show router1
    ip a
    route
fi

PUB_NET=$(neutron net-list | awk '/ public / {print $2}')
PRIV_NET=$(neutron net-list | awk '/ private / {print $2}')
ROUTER_ID=$(neutron router-list | awk ' /router1/ {print $2}')
# Set the Neutron gateway for router
neutron router-gateway-set $ROUTER_ID $PUB_NET

# route private network through public network
ip route replace 10.0.0.0/24 via {{ ansible_eth0.ipv4.address.rsplit('.', 1)[0] + '.128' }}

BOOT_TIMEOUT=${BOOT_TIMEOUT:-300}

myping() {
    ii=$2
    while [ $ii -gt 0 ] ; do
        if ping -q -W1 -c1 -n $1 ; then
            break
        fi
        ii=`expr $ii - 1`
        sleep 1
    done
    if [ $ii = 0 ] ; then
        echo $LINENO "server did not respond to ping $1"
        return 1
    fi
    return 0
}

if [ -z "$PRIV_NET" ] ; then
    echo Error: could not find private network
    openstack network list --long
    nova net-list
    neutron subnet-list
    exit 1
fi
VM_UUID=$(openstack server create rhel7 --flavor m1.small --image rhel7 --security-group default --nic net-id=$PRIV_NET | awk '/ id / {print $4}')

ii=$BOOT_TIMEOUT
while [ $ii -gt 0 ] ; do
    if openstack server show rhel7|grep ACTIVE ; then
        break
    fi
    if openstack server show rhel7|grep ERROR ; then
        echo could not create server
        openstack server show rhel7
        exit 1
    fi
    ii=`expr $ii - 1`
done

if [ $ii = 0 ] ; then
    echo $LINENO server was not active after $BOOT_TIMEOUT seconds
    openstack server show rhel7
    exit 1
fi

VM_IP=$(openstack server show rhel7 | sed -n '/ addresses / { s/^.*addresses.*private=\([0-9.][0-9.]*\).*$/\1/; p; q }')
if ! myping $VM_IP $BOOT_TIMEOUT ; then
    echo $LINENO "server did not respond to ping $VM_IP"
    exit 1
fi

PORTID=$(neutron port-list --device-id $VM_UUID | awk "/$VM_IP/ {print \$2}")
FIPID=$(neutron floatingip-create public | awk '/ id / {print $4}')
neutron floatingip-associate $FIPID $PORTID
FLOATING_IP=$(neutron floatingip-list | awk "/$VM_IP/ {print \$6}")
FLOATID=$(neutron floatingip-list | awk "/$VM_IP/ {print \$2}")

if ! myping $FLOATING_IP $BOOT_TIMEOUT ; then
    echo $LINENO "server did not respond to ping $FLOATING_IP"
    exit 1
fi
