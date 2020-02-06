#!/bin/bash

set -euo pipefail

declare -A PROFILE_MAP

VM_MASTER="k8s-master"
VM_NODE="k8s-node01"
VM_ISCSI="k8s-iscsi"
ADMIN_USER="ubuntu"

VM_PROFILE_NAME="vm_base"

HERE_REL=`dirname $0`
HERE=`realpath $HERE_REL`

PROFILE_MAP[$VM_PROFILE_NAME]=`mktemp` 

for profile in `ls $HERE/profiles`
do
    PROFILE_MAP[${profile%%.yaml}]="$HERE/profiles/$profile"
done


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
--admin-user    The admin user with full sudo access. Defaults to ubuntu.
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
    --admin-user)
        ADMIN_USER=$2
        shift;;
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
  eth0:
    name: eth0
    nictype: bridged
    parent: $LXD_BR_NAME
    type: nic
name: $VM_PROFILE_NAME
EOF

create_profiles() {
    PROFILES=`lxc profile list --format csv`
    for profile in ${!PROFILE_MAP[@]}
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

create_iscsi_storage_class() {
    PASSWD=$1
    [ -z $PASSWD ] && throw "password may not be empty"


    LXC_INFO=`lxc list $VM_ISCSI --format yaml`
    ISCSI_SRV_IP=`python3 -c 'import yaml; import sys; data=yaml.safe_load(sys.argv[1]); net=data[0]["state"]["network"]; print([j["address"] for i in net for j in net[i]["addresses"] if i != "lo" and j["family"] == "inet"][0])' "$LXC_INFO"`
    [ -z $ISCSI_SRV_IP ] && throw "failed to find VM IP for $VM_ISCSI"

    lxc exec $VM_MASTER -- /bin/bash -c 'mkdir -p /home/'$ADMIN_USER'/iscsi'
    lxc file push "$HERE/iscsi/iscsi-provisioner-class.yaml" $VM_MASTER/home/$ADMIN_USER/iscsi/iscsi-provisioner-class.yaml
    lxc file push "$HERE/iscsi/iscsi-provisioner-d.yaml" $VM_MASTER/home/$ADMIN_USER/iscsi/iscsi-provisioner-d.yaml
    lxc exec $VM_MASTER -- /bin/bash -c 'sudo -i -u '$ADMIN_USER' -- kubectl create secret generic targetd-account --from-literal=username=admin --from-literal=password='$PASSWD' --from-literal=targetd_ip='$ISCSI_SRV_IP' -n default'
    lxc exec $VM_MASTER -- /bin/bash -c 'sed -i "s|ALLOWED_NODES|iqn.1993-08.org.debian:01:'$VM_NODE'|g" /home/'$ADMIN_USER'/iscsi/iscsi-provisioner-class.yaml'
    lxc exec $VM_MASTER -- /bin/bash -c 'sed -i "s|ISCSI_SERVER_IP|'$ISCSI_SRV_IP'|g" /home/'$ADMIN_USER'/iscsi/iscsi-provisioner-class.yaml'
    lxc exec $VM_MASTER -- /bin/bash -c 'chown '$ADMIN_USER':'$ADMIN_USER' -R /home/'$ADMIN_USER'/iscsi'
    lxc exec $VM_MASTER -- /bin/bash -c 'sudo -i -u '$ADMIN_USER' -- kubectl create -f /home/'$ADMIN_USER'/iscsi/iscsi-provisioner-d.yaml'
    lxc exec $VM_MASTER -- /bin/bash -c 'sudo -i -u '$ADMIN_USER' -- kubectl create -f /home/'$ADMIN_USER'/iscsi/iscsi-provisioner-class.yaml'
}

create_machines() {
    lxc launch ubuntu:18.04 --vm --profile=$VM_PROFILE_NAME --profile=vm-medium --profile=vm-ds-small $VM_MASTER
    lxc launch ubuntu:18.04 --vm --profile=$VM_PROFILE_NAME --profile=vm-large --profile=vm-ds-large $VM_NODE
    lxc launch ubuntu:18.04 --vm --profile=$VM_PROFILE_NAME --profile=vm-small --profile=vm-ds-xlarge $VM_ISCSI

    (wait_for_agent $VM_MASTER) &
    (wait_for_agent $VM_NODE) &
    (wait_for_agent $VM_ISCSI) &

    wait || throw "Failed to spawn vms"

    SETUP_SCRIPT_PATH="$HERE/setup_k8s.sh"
    SETUP_NFS="$HERE/setup_k8s_iscsi.sh"
    SETUP_KUBEVIRT_SCRIPT_PATH="$HERE/setup_kubevirt.sh"
    lxc file push $SETUP_SCRIPT_PATH $VM_MASTER/setup_k8s.sh
    lxc file push $SETUP_KUBEVIRT_SCRIPT_PATH $VM_MASTER/setup_kubevirt.sh
    lxc file push $SETUP_NFS $VM_ISCSI/setup_k8s_iscsi.sh
    lxc exec $VM_MASTER -- /bin/bash -c 'chmod +x /setup_*'
    lxc file push $SETUP_SCRIPT_PATH $VM_NODE/setup_k8s.sh
    lxc exec $VM_NODE -- /bin/bash -c 'chmod +x /setup_*'

    (lxc exec $VM_MASTER -- /bin/bash -c '/setup_k8s.sh --role master --admin-user '$ADMIN_USER'') &
    MASTER_PID=$!

    (lxc exec $VM_NODE -- /bin/bash -c '/setup_k8s.sh --admin-user '$ADMIN_USER'') &
    NODE_PID=$!

    TARGET_PASSWD=`uuidgen`
    (lxc exec $VM_ISCSI -- /bin/bash -c '/setup_k8s_iscsi.sh --password '$TARGET_PASSWD'') &
    NFS_PID=$!

    wait $NODE_PID || throw "failed to set up k8s on $VM_NODE"
    wait $MASTER_PID || throw "failed to set up k8s on $VM_MASTER"
    wait $NFS_PID || throw "failed to set up k8s NFS on $VM_ISCSI"

    # join node to master
    JOIN_CMD=`lxc exec $VM_MASTER -- /bin/bash -c 'kubeadm token create --print-join-command 2>&1 | tail -n1'`
    lxc exec $VM_NODE -- $JOIN_CMD
    sleep 60
    lxc exec $VM_MASTER -- /bin/bash -c '/setup_kubevirt.sh --admin-user '$ADMIN_USER''

    create_iscsi_storage_class $TARGET_PASSWD
}

create_profiles
create_machines
