#!/bin/bash

set -exuo pipefail

declare -A PROFILE_MAP

VM_MASTER="k8s-master"
VM_NODE="k8s-node01"

VM_PROFILE=`mktemp`
VM_SMALL_PROFILE=`mktemp`
VM_MEDIUM_PROFILE=`mktemp`
VM_LARGE_PROFILE=`mktemp`

VM_PROFILE_NAME="vm_base"
VM_SMALL_PROFILE_NAME="vm-small"
VM_MEDIUM_PROFILE_NAME="vm-medium"
VM_LARGE_PROFILE_NAME="vm-large"

PROFILE_MAP[$VM_PROFILE_NAME]=`mktemp` 
PROFILE_MAP[$VM_SMALL_PROFILE_NAME]=`mktemp` 
PROFILE_MAP[$VM_MEDIUM_PROFILE_NAME]=`mktemp` 
PROFILE_MAP[$VM_LARGE_PROFILE_NAME]=`mktemp` 

GH_PROFILE=""
LXD_BR_NAME="lxdbr0"
CLOBBER=0

throw() {
    echo $1
    exit 1
}

usage() {
    echo "$0 flags
    
--github-user   The github username from which we fetch the public key
--lxd-br-name   LXD bridge name to use for VMs. Defaults to lxdbr0.
--clobber       Use this option to overwrite any existing settings with those in this script."
}

while [ $# -gt 0 ]
do
    case $1 in
    --github-user)
        GH_PROFILE=${2}
        shift;;
    --lxd-br-name)
        LXD_BR_NAME=${2}
        shift;;
    --clobber)
        CLOBBER=1;;
    *)
        usage
        exit 1;;
    esac
    shift
done



if [ -z $GH_PROFILE ]
then
    usage
    echo ""
    throw "please set --github-user flag"
fi

if [ -z $LXD_BR_NAME ]
then
    usage
    echo ""
    throw "please set --lxd-br-name flag"
fi

(ip link sh $LXD_BR_NAME 2>&1) > /dev/null || throw "interface $LXD_BR_NAME does not exist"

cat > ${PROFILE_MAP[$VM_PROFILE_NAME]} << EOF
config:
  user.user-data: |
    #cloud-config
    ssh_pwauth: yes
    apt_mirror: http://ro.archive.ubuntu.com/ubuntu/
    users:
      - name: ubuntu
        ssh_import_id: $GH_PROFILE
        lock_passwd: true
        groups: lxd
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
    runcmd:
      - ["mount", "-t", "9p", "config", "/mnt"]
      - ["cd", "/mnt"]
      - ["./install.sh"]
      - ["cd", "-"]
      - ["umount", "/mnt"]
      - ["systemctl", "start", "lxd-agent-9p", "lxd-agent"]
description: base VM profile
devices:
  config:
    source: cloud-init:config
    type: disk
name: $VM_PROFILE_NAME
EOF

cat > ${PROFILE_MAP[$VM_SMALL_PROFILE_NAME]} << EOF
config:
  limits.cpu: "2"
  limits.memory: 2048MB
description: "A small VM profile"
devices:
  eth0:
    name: eth0
    nictype: bridged
    parent: lxdbr0
    type: nic
  root:
    path: /
    pool: default
    size: 10GB
    type: disk
name: $VM_SMALL_PROFILE_NAME
EOF


cat > ${PROFILE_MAP[$VM_MEDIUM_PROFILE_NAME]} << EOF
config:
  limits.cpu: "2"
  limits.memory: 4096MB
description: "A medium sized VM profile"
devices:
  eth0:
    name: eth0
    nictype: bridged
    parent: lxdbr0
    type: nic
  root:
    path: /
    pool: default
    size: 20GB
    type: disk
name: $VM_MEDIUM_PROFILE_NAME
EOF

cat > ${PROFILE_MAP[$VM_LARGE_PROFILE_NAME]} << EOF
config:
  limits.cpu: "4"
  limits.memory: 8192MB
description: "A large VM profile"
devices:
  eth0:
    name: eth0
    nictype: bridged
    parent: lxdbr0
    type: nic
  root:
    path: /
    pool: default
    size: 40GB
    type: disk
name: $VM_LARGE_PROFILE_NAME
EOF

create_profiles() {
    PROFILES=`lxc profile list --format csv`
    for profile in $VM_LARGE_PROFILE_NAME $VM_MEDIUM_PROFILE_NAME $VM_SMALL_PROFILE_NAME $VM_PROFILE_NAME
    do
        PROFILES=`lxc profile list --format csv`
        if [[ ! "${PROFILES}" =~ "${profile}" ]]
        then
            lxc profile create "$profile"
        else
            if [ $CLOBBER -eq 0 ]
            then
                throw "Profile $profile already exists. Use --clobber to overwrite it."
            fi
        fi
        lxc profile edit "$profile" < ${PROFILE_MAP[$profile]}
    done
}

wait_for_agent() {
    [ -z $1 ] && throw "missing container name"
    retries=60
    r=0
    while [ $r -lt $retries ]
    do
        ERR=0
        lxc exec $1 whoami 2>&1 > /dev/null || ERR=$?
        if [ $ERR -ne 0 ]
        then
            r=$(($r + 1))
            sleep 5
            continue
        fi
        return 0
    done 
}

create_machines() {
    lxc launch ubuntu:18.04 --vm --profile=$VM_PROFILE_NAME --profile=$VM_MEDIUM_PROFILE_NAME $VM_MASTER
    lxc launch ubuntu:18.04 --vm --profile=$VM_PROFILE_NAME --profile=$VM_LARGE_PROFILE_NAME $VM_NODE
    wait_for_agent $VM_MASTER
    wait_for_agent $VM_NODE

    SETUP_SCRIPT_DIR=`dirname $0`
    SETUP_SCRIPT_PATH="$SETUP_SCRIPT_DIR/setup_k8s.sh"
    SETUP_KUBEVIRT_SCRIPT_PATH="$SETUP_SCRIPT_DIR/setup_kubevirt.sh"
    lxc file push $SETUP_SCRIPT_PATH $VM_MASTER/setup_k8s.sh
    lxc file push $SETUP_KUBEVIRT_SCRIPT_PATH $VM_MASTER/setup_kubevirt.sh
    lxc exec $VM_MASTER -- /bin/bash -c 'chmod +x /setup_*'
    lxc file push $SETUP_SCRIPT_PATH $VM_NODE/setup_k8s.sh
    lxc exec $VM_NODE -- /bin/bash -c 'chmod +x /setup_*'

    (lxc exec $VM_MASTER -- /bin/bash -c '/setup_k8s.sh --role master') &
    MASTER_PID=$!

    (lxc exec $VM_NODE /setup_k8s.sh) &
    NODE_PID=$!

    wait $NODE_PID || throw "failed to set up k8s on $VM_NODE"
    wait $MASTER_PID || throw "failed to set up k8s on $VM_MASTER"

    # join node to master
    JOIN_CMD=`lxc exec $VM_MASTER -- /bin/bash -c 'kubeadm token create --print-join-command 2>&1 | tail -n1'`
    lxc exec $VM_NODE -- $JOIN_CMD
    sleep 60
    lxc exec $VM_MASTER -- /bin/bash -c '/setup_kubevirt.sh'
}

create_profiles
create_machines
