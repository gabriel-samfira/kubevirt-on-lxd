#!/bin/bash

set -e

POD_CIDR="10.244.0.0/16"
ROLE="node"

while [ $# -gt 0 ]
do
    case $1 in
    --pod-cidr)
        POD_CIDR=${2}
        shift;;
    --role)
        ROLE=${2}
        shift;;
    esac
    shift
done

create_docker_group() {
	sudo addgroup --system docker || true
}

setup_k8s() {
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
	curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
	sudo apt install -y docker-ce apt-transport-https
	echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
	sudo apt-get update
	sudo apt install -y kubeadm  kubelet kubernetes-cni jq
}

setup_master() {
	sudo kubeadm init --pod-network-cidr=$POD_CIDR
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config
}

throw() {
	echo $1
	exit 1
}

setup_pod_network() {
	FLANNEL_DEFAULT_CIDR="10.244.0.0/16"
	[ -z "$POD_CIDR" ] && throw "POD_CIDR is empty" 
	wget -q https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml -O /tmp/kube-flannel.yml
	sed -i "s|$FLANNEL_DEFAULT_CIDR|$POD_CIDR|g" /tmp/kube-flannel.yml
	kubectl apply -f /tmp/kube-flannel.yml
}

create_docker_group
setup_k8s

if [ $ROLE == "master" ]
then
    setup_master
    setup_pod_network
fi
