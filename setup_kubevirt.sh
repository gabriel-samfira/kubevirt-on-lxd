#!/bin/bash

set -e
ADMIN_USER="ubuntu"

while [ $# -gt 0 ]
do
    case $1 in
    --admin-user)
        ADMIN_USER=$2
        shift;;
    esac
    shift
done

throw() {
    echo $1
    exit 1
}

getent passwd $ADMIN_USER || throw "admin user $ADMIN_USER does not exist"

setup_kubevirt() {
    USER_HOME=`eval echo ~$ADMIN_USER`
    export KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | jq -r .tag_name)
    sudo -i -u $ADMIN_USER -- kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml
    sudo -i -u $ADMIN_USER -- kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml
    mkdir $USER_HOME/bin
    wget -q -O $USER_HOME/bin/virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
    chmod +x $USER_HOME/bin/virtctl
    grep "$USER_HOME/bin" $USER_HOME/.bashrc || echo 'export PATH='$USER_HOME'/bin:$PATH' >> $USER_HOME/.bashrc
    sudo -i -u $ADMIN_USER -- kubectl -n kubevirt wait --timeout=600s kv kubevirt --for condition=Available
}

setup_kubevirt
