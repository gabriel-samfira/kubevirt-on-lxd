#!/bin/bash

set -e

POD_CIDR="10.244.0.0/16"
ROLE="node"
ADMIN_USER="ubuntu"
WITH_ISCSI=0
WITH_HOSTPATH=0
MASTER_IP="127.0.0.1"

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
    --with-iscsi)
        WITH_ISCSI=${2}
        shift;;
    --with-hostpath)
        WITH_HOSTPATH=${2}
        shift;;
    --master-ip)
        MASTER_IP=${2}
        shift;;
    esac
    shift
done

throw() {
	echo $1
	exit 1
}

[ $WITH_ISCSI -eq 0 ] && [ $WITH_HOSTPATH -eq 0 ] && throw "at least one CSI must be enabled"
getent passwd $ADMIN_USER 2>&1 > /dev/null || throw "admin user $ADMIN_USER does not exist"

create_docker_group() {
	sudo addgroup --system docker || true
    sudo adduser $ADMIN_USER docker || true
}

setup_iscsi() {
    sudo apt-get install -y -q open-iscsi
    echo "InitiatorName=iqn.1993-08.org.debian:01:$HOSTNAME" > /etc/iscsi/initiatorname.iscsi
    sudo systemctl enable iscsid
    sudo systemctl stop iscsid || true
    sudo systemctl start iscsid
}

setup_k8s() {
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
	curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
	sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    #sudo add-apt-repository -y ppa:gluster/glusterfs-7
	#sudo apt install -y docker-ce apt-transport-https glusterfs-client
	sudo apt install -y -q docker-ce apt-transport-https
	echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
	sudo apt-get update -q
	sudo apt install -y -q kubeadm  kubelet kubernetes-cni jq git
}

setup_master() {
    DEFAULTS=`kubeadm config print init-defaults`
    python3 -c 'import yaml;import sys; data=list(yaml.safe_load_all(sys.argv[1])); doc=[i for i in data if i.get("controllerManager", None) is not None][0]; doc["controllerManager"] = {"extraArgs": {"enable-hostpath-provisioner": "true"}};doc["networking"]["podSubnet"] = "'$POD_CIDR'"; doc2 = [i for i in data if i.get("localAPIEndpoint", None) is not None][0]; doc2["localAPIEndpoint"]["advertiseAddress"] = "'$MASTER_IP'" ;print(yaml.dump_all(data))' "$DEFAULTS" > /tmp/kubeadm.cfg
	sudo kubeadm init --config=/tmp/kubeadm.cfg

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

echo "Running create_docker_group on $HOSTNAME"
create_docker_group
echo "Running setup_k8s on $HOSTNAME"
setup_k8s
[ $WITH_ISCSI -eq 1 ] && setup_iscsi

if [ $ROLE == "master" ]
then
    echo "Running setup_master on $HOSTNAME"
    setup_master
    echo "Running setup_pod_network on $HOSTNAME"
    setup_pod_network
fi
