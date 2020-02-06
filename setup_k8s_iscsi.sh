#!/bin/bash

set -e

HERE=`dirname $0`

while [ $# -gt 0 ]
do
    case $1 in
    --password)
        PASSWORD=${2}
        shift;;
    esac
    shift
done


throw() {
    echo $1
    exit 1
}

if [ -z "$PASSWORD" ]
then
    throw "--password is mandatory"
fi

setup_packages() {
    sudo apt-get update
    sudo apt-get install -y python3-rtslib-fb python3-pip \
        python3-blockdev libblockdev-lvm2 \
        libblockdev-lvm-dbus2 lvm2-dbusd python3-setproctitle \
        targetcli-fb gir1.2-blockdev-2.0 git
}

install_targetd() {
    git clone https://github.com/open-iscsi/targetd
    pushd targetd
    sudo python3 setup.py install
    popd
    sudo mkdir -p /etc/target/

    cat > /etc/target/targetd.yaml << EOF
password: $PASSWORD

# defaults below; uncomment and edit
# if using a thin pool, use <volume group name>/<thin pool name>
# e.g vg-targetd/pool
pool_name: vg-targetd/pool
user: admin
ssl: false
target_name: iqn.2003-01.org.linux-iscsi.coriolis:targetd
EOF

    cat > /etc/systemd/system/targetd.service << EOF
[Unit]
Description=targetd storage array API daemon
Requires=targetd.service
After=targetd.service

[Service]
ExecStart=/usr/local/bin/targetd

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable targetd.service
    sudo systemctl start targetd.service
}

create_lvm2_loopback_device() {
    if [ ! -f /var/disk.img ]
    then
        AVAIL_SPACE_KB=`df --output=avail / | tail -n1`
        AVAIL_SPACE=$(($AVAIL_SPACE_KB - 2*1024*1024))
        if [ $AVAIL_SPACE -lt $((10 * 1024 * 1024)) ]
        then
            throw "not enough free space on /. At least 12 GB are required."
        fi
        AVAIL_SPACE_BYTES=$(($AVAIL_SPACE * 1024))
        /usr/bin/truncate /var/disk.img --size $AVAIL_SPACE_BYTES
    fi

    cat > /etc/systemd/system/activate-loop.service << EOF
[Unit]
Description=Activate loop device
DefaultDependencies=no
After=systemd-udev-settle.service
Before=lvm2-activation-early.service
Wants=systemd-udev-settle.service

[Service]
ExecStart=/sbin/losetup /dev/loop0 /var/disk.img
Type=oneshot

[Install]
WantedBy=local-fs.target
EOF
    systemctl daemon-reload
    systemctl enable activate-loop.service
    systemctl start activate-loop.service
}

configure_lvm2() {
    losetup -a | grep /dev/loop0 > /dev/null || throw "loopback device not configured"
    pvcreate /dev/loop0 2>&1 > /dev/null
    vgcreate vg-targetd /dev/loop0 2>&1 > /dev/null
    FREE_PE=`vgdisplay vg-targetd| grep "Free "| awk '{print $5}'`
    lvcreate -l $(($FREE_PE - 64)) --thinpool pool vg-targetd
}

setup_packages
create_lvm2_loopback_device
configure_lvm2
install_targetd
