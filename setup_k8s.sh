#!/bin/bash

set -e

POD_CIDR="10.244.0.0/16"
ROLE="node"
ADMIN_USER="ubuntu"

while [ $# -gt 0 ]
do
    case $1 in
    --pod-cidr)
        POD_CIDR=${2}
        shift;;
    --role)
        ROLE=${2}
        shift;;
    --admin-user)
        ADMIN_USER=${2}
        shift;;
    esac
    shift
done

throw() {
	echo $1
	exit 1
}

getent passwd $ADMIN_USER || throw "admin user $ADMIN_USER does not exist"

create_docker_group() {
	sudo addgroup --system docker || true
    sudo adduser $ADMIN_USER docker || true
}

setup_k8s() {
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
	curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    #sudo add-apt-repository -y ppa:gluster/glusterfs-7
	#sudo apt install -y docker-ce apt-transport-https glusterfs-client
	sudo apt install -y docker-ce apt-transport-https
	echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
	sudo apt-get update
	sudo apt install -y kubeadm  kubelet kubernetes-cni jq open-iscsi

    echo "InitiatorName=iqn.1993-08.org.debian:01:$HOSTNAME" > /etc/iscsi/initiatorname.iscsi
    sudo systemctl enable iscsid
    sudo systemctl stop iscsid || true
    sudo systemctl start iscsid
}

setup_master() {
	sudo kubeadm init --pod-network-cidr=$POD_CIDR

    USER_HOME=`eval echo ~$ADMIN_USER`
	mkdir -p $USER_HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $USER_HOME/.kube/config
	sudo chown $ADMIN_USER:$ADMIN_USER $USER_HOME/.kube/config
}

setup_pod_network() {
	FLANNEL_DEFAULT_CIDR="10.244.0.0/16"
	[ -z "$POD_CIDR" ] && throw "POD_CIDR is empty" 
	sudo -i -u $ADMIN_USER -- wget -q https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml -O /tmp/kube-flannel.yml
	sed -i "s|$FLANNEL_DEFAULT_CIDR|$POD_CIDR|g" /tmp/kube-flannel.yml
	sudo -i -u $ADMIN_USER -- kubectl apply -f /tmp/kube-flannel.yml
}

create_docker_group
setup_k8s

if [ $ROLE == "master" ]
then
    setup_master
    setup_pod_network
fi
