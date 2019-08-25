#!/bin/bash -xe

export ARTIFACTSDIR=$PWD/exported-artifacts

export LIBGUESTFS_BACKEND=direct
export LIBGUESTFS_TMPDIR=/var/tmp
export LIBGUESTFS_CACHEDIR=$LIBGUESTFS_TMPDIR

VERSION="4.4.0"
RELEASE_RPM="https://resources.ovirt.org/pub/yum-repo/ovirt-release-master.rpm"

prepare() {
    mkdir -p "$ARTIFACTSDIR"

    mknod /dev/fuse c 10 229 || :
    mknod /dev/kvm c 10 232 || :
    mknod /dev/vhost-net c 10 238 || :
    mkdir /dev/net || :
    mknod /dev/net/tun c 10 200 || :
    seq 0 9 | xargs -I {} mknod /dev/loop{} b 7 {} || :

    virsh list --name | xargs -rn1 virsh destroy || :
    virsh list --all --name | xargs -rn1 virsh undefine --remove-all-storage || :
    losetup -O BACK-FILE | grep -v BACK-FILE | grep iso$ | xargs -r umount -dvf ||:

    virt-host-validate ||:
}

build() {
    dist="$(rpm --eval %{dist})"
    dist=${dist##.}

    if [[ ${dist} = fc* ]]; then
        fcrel="$(rpm --eval %{fedora})"
        ./build.sh -r ${RELEASE_RPM} -f ${fcrel} -v ${VERSION} -o ${ARTIFACTSDIR}
    else
        echo "Not building for non-fedora hosts"
    fi
}

main() {
    prepare
    build
}

main
