#!/bin/bash
set -x
SERVERS="master node01"

DIRNAME=$(dirname $0)
RHSM_USERNAME=$(cat $DIRNAME/rhn-username)
RHSM_PASSWORD=$(cat $DIRNAME/rhn-password)
RHSM_POOLID=$(cat $DIRNAME/rhn-poolid)

# config Network Interface

cat << EOF >> netconfig.sh
ETH0_HWADDR=\$(/usr/sbin/ip a | grep -A1 eth0 | grep link | cut -d' ' -f6)
sudo sh -c "cat << EOM >> /etc/sysconfig/network-scripts/ifcfg-eth0
HWADDR=\$ETH0_HWADDR
EOM"
sudo systemctl restart network
EOF


scp ./netconfig.sh vagrant@192.168.32.11:/tmp/netconfig.sh
scp ./netconfig.sh vagrant@192.168.32.21:/tmp/netconfig.sh

for svr in $SERVERS ; do
echo $svr
vagrant ssh $svr --command "sudo /bin/bash /tmp/netconfig.sh"
done

# config docker
for svr in $SERVERS ; do
echo $svr
vagrant ssh $svr --command "sudo cp /etc/sysconfig/docker /etc/sysconfig/docker.bk; sudo perl -i -pe \'s/^OPTIONS/OPTIONS=\'--selinux-enabled --insecure-registry 172.30.0.0\/16\'\/g"
done

for svr in $SERVERS ; do
echo $svr
vagrant ssh $svr --command "sudo subscription-manager register --username='$RHSM_USERNAME' --password='$RHSM_PASSWORD'"
vagrant ssh $svr --command "sudo subscription-manager attach --pool='$RHSM_POOLID'"
vagrant ssh $svr --command "sudo subscription-manager repos --disable='*'; sudo subscription-manager repos --enable='rhel-7-server-rpms' --enable='rhel-7-server-extras-rpms' --enable='rhel-7-server-ose-3.2-rpms'"
vagrant ssh $svr --command "sudo yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion"
vagrant ssh $svr --command "sudo yum -y update"
vagrant ssh $svr --command "sudo yum -y install atomic-openshift-utils"
vagrant ssh $svr --command "sudo yum -y erase kubernetes kubernetes-client kubernetes-master kubernetes-node"
vagrant ssh $svr --command "sudo -c 'echo 192.168.32.11 master.192.168.32.11.xip.io >> /etc/hosts'"
vagrant ssh $svr --command "sudo -c 'echo 192.168.32.21 node01.192.168.32.21.xip.io >> /etc/hosts'"
done

vagrant ssh master --command "ssh-keygen; ssh-copy-id -i ~/.ssh/id_rsa.pub node01.192.168.32.21.xip.io; ssh-copy-id -i ~/.ssh/id_rsa.pub master.192.168.32.11.xip.io"


cat << EOF > ansible_hosts
# use option '-i INVENTORY'; INVENTORY is this file

# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
# SSH user, this user should allow ssh based auth without requiring a password
ansible_ssh_user=vagrant

# If ansible_ssh_user is not root, ansible_sudo must be set to true
ansible_sudo=true

deployment_type=openshift-enterprise

# uncomment the following to enable htpasswd authentication; defaults to DenyAllPasswordIdentityProvider
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

# application subdomains
osm_default_subdomain=192.168.32.11.xip.io

# host group for masters
[masters]
master.192.168.32.11.xip.io openshift_public_hostname=master.192.168.32.11.xip.io openshift_public_ip=192.168.32.11 openshift_hostname=master.192.168.32.11.xip.io openshift_ip=192.168.32.11

# host group for nodes, includes region info
[nodes]
master.192.168.32.11.xip.io openshift_node_labels="{'region': 'infra', 'zone': 'default'}" openshift_public_hostname=master.192.168.32.11.xip.io openshift_public_ip=192.168.32.11 openshift_hostname=master.192.168.32.11.xip.io openshift_ip=192.168.32.11
node01.192.168.32.21.xip.io openshift_node_labels="{'region': 'primary', 'zone': 'east'}" openshift_public_hostname=node01.192.168.32.21.xip.io openshift_public_ip=192.168.32.21 openshift_hostname=node01.192.168.32.21.xip.io openshift_ip=192.168.32.21
EOF

scp ./ansible_hosts vagrant@192.168.32.11:/tmp/ansible_hosts
vagrant ssh master --command "sudo cp /tmp/ansible_hosts /etc/ansible/hosts"
vagrant ssh master --command "ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml"


vagrant ssh master --command "oc label node master.192.168.32.11.xip.io region=infra zone=default"
vagrant ssh master --command "sudo mkdir -p /registry; sudo chown 1001:root /registry"

vagrant ssh master --command "oadm manage-node master.192.168.32.11.xip.io --schedulable=true"

vagrant ssh master --command "sudo oadm registry --service-account=registry     --config=/etc/origin/master/admin.kubeconfig     --credentials=/etc/origin/master/openshift-registry.kubeconfig     --images='registry.access.redhat.com/openshift3/ose-\${component}:\${version}' --mount-host=/registry --selector='region=infra'"

vagrant ssh master --command "sudo oadm router --service-account=router  --config='/etc/origin/master/admin.kubeconfig'"

echo "after verify running Docker Registr and Router, execute the following command. oadm manage-node master.192.168.32.11.xip.io --schedulable=false"
