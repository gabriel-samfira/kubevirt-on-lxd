#!/bin/bash

set -e

setup_kubevirt() {
    export KUBEVIRT_VERSION=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | jq -r .tag_name)
    kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml
    kubectl create -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml
    mkdir $HOME/bin
    wget -q -O $HOME/bin/virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64
    chmod +x $HOME/bin/virtctl
    if [[ ! ${PATH} =~ "${HOME}/bin" ]]
    then
        echo "export PATH=$HOME/bin:$PATH" >> $HOME/.bashrc
        source $HOME/.bashrc
    fi
    kubectl -n kubevirt wait --timeout=600s kv kubevirt --for condition=Available
}

setup_kubevirt
