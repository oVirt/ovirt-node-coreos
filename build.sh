#!/bin/bash -ex

CONFIG_DIR=$(dirname $(realpath $0))

export COREOS_ASSEMBLER_CONFIG_GIT=${CONFIG_DIR}

setup_repos() {
    local ovirt_release_rpm="$1"
    local fedora_release="$2"

    pushd $CONFIG_DIR
    # Grab basic fedora-coreos-config
    rm -rf fedora-coreos-config
    git clone --depth=1 https://github.com/coreos/fedora-coreos-config.git
    ln -sf fedora-coreos-config/*.repo .
    ln -sf fedora-coreos-config/minimal.yaml .
    ln -sf fedora-coreos-config/image.yaml .
    ln -sf fedora-coreos-config/installer .
    ln -sf fedora-coreos-config/overlay.d .
    ln -sf fedora-coreos-config/grub2-removals.yaml .
    ln -sf fedora-coreos-config/fedora-coreos-base.yaml ovirt-coreos-base.yaml

    # Rebrand installer
    sed -i 's/Fedora CoreOS/oVirt Node CoreOS/' \
        installer/isolinux/isolinux.cfg installer/EFI/fedora/grub.cfg \

    # Extract repo files from release.rpm
    tmpdir=$(mktemp -d)
    curl -L -o "${tmpdir}/release.rpm" ${ovirt_release_rpm}
    rpm2cpio "${tmpdir}/release.rpm" | cpio -divuD ${tmpdir}
    find ${tmpdir} -name "ovirt-f${fedora_release}-deps.repo" -exec cp {} . \;
    find ${tmpdir} -name "ovirt-snapshot.repo" -exec cp {} . \;
    sed -i -e "s/@DIST@/fc/g; s/@URLKEY@/mirrorlist/g" ovirt-snapshot.repo
    sed -i -e '/glusterfs\// s/fedora-/f/' ovirt-f${fedora_release}-deps.repo
    rm -rf ${tmpdir}

    for x in *.repo; do
        sed -i 's/^gpgcheck=.*/gpgcheck=0/g' $x
    done

    # Generate ovirt-node-config
    sed -i "s/^releasever:.*/releasever: \"${fedora_release}\"/" ovirt-coreos-base.yaml

    # Setup packages
    echo "  - ovirt-host" >> ovirt-coreos-base.yaml
    sed -i \
        -e /nfs-utils-coreos/d \
        -e /zincati/d \
        -e /fedora-coreos-pinger/d \
        ovirt-coreos-base.yaml

    # Setup repos
    echo "repos:" >> ovirt-coreos-base.yaml
    grep '^\[' *.repo | grep -v fedora-updates-testing | \
        cut -d: -f2 | \
        sed 's/\[\(.*\)\]/  - \1/' >> ovirt-coreos-base.yaml
    popd
}

handle_overrides() {
    local workdir="$1"

    # Rebuild vdsm for now until we discuss how we move from /rhev/data-center
    # to some other supported location
    echo "Rebuilding vdsm"
    tmpdir=$(mktemp -d)
    git clone https://gerrit.ovirt.org/vdsm ${tmpdir}
    pushd ${tmpdir}
    mkdir rpmbuild
    ./autogen.sh
    make dist
    make rpm PACKAGE_RELEASE="$(date +%Y%m%d%H)fcos" \
             DIST_ARCHIVES="--define \"_topdir ${tmpdir}/rpmbuild\" --define=\"vdsm_repo /run/rhev/data-center\" vdsm*tar.gz"
    popd

    mkdir -p ${workdir}/overrides/rpm
    find ${tmpdir}/rpmbuild/RPMS -name "*.rpm" -exec mv -v {} ${workdir}/overrides/rpm \;
    rm -rf ${tmpdir}
}

setup_cosa() {
    local workdir="$1"

    if [[ -z ${COREOS_ASSEMBLER_CONTAINER} ]]; then
        docker pull quay.io/coreos-assembler/coreos-assembler:latest
    fi

    cosa_git=${CONFIG_DIR}/coreos-assembler
    rm -rf ${cosa_git}
    git clone --depth=1 https://github.com/coreos/coreos-assembler.git ${cosa_git}
    sed -i 's/percent 20/percent 30/' ${cosa_git}/src/cmd-buildextend-metal
    #sed -i '/^ostree admin/a ls -la rootfs' ${cosa_git}/src/create_disk.sh
    #sed -i '/Running:/a ostree ls --repo="${tmprepo}" ovirt/44/x86_64/coreos ||:' ${cosa_git}/src/cmdlib.sh
    #sed -i '/Very special/i ostree ls --repo="${tmprepo}" ovirt/44/x86_64/coreos ||:' ${cosa_git}/src/cmd-build
    export COREOS_ASSEMBLER_GIT=${cosa_git}

    setfacl -m u:1000:rwx ${workdir}
    setfacl -d -m u:1000:rwx ${workdir}
    selinuxenabled && chcon system_u:object_r:container_file_t:s0 ${workdir} ||:
}

cosa() {
    env | grep COREOS_ASSEMBLER
    docker run --rm -v ${PWD}:/srv/ --userns=host --device /dev/kvm --name cosa               \
        --tmpfs /tmp -v /var/tmp:/var/tmp --privileged                                        \
        ${COREOS_ASSEMBLER_CONFIG_GIT:+-v $COREOS_ASSEMBLER_CONFIG_GIT:/srv/src/config/:ro}   \
        ${COREOS_ASSEMBLER_GIT:+-v $COREOS_ASSEMBLER_GIT/src/:/usr/lib/coreos-assembler/:ro}  \
        ${COREOS_ASSEMBLER_CONTAINER_RUNTIME_ARGS}                                            \
        ${COREOS_ASSEMBLER_CONTAINER:-quay.io/coreos-assembler/coreos-assembler:latest} $@
    return $?
}

main() {
    local ovirt_release_rpm=""
    local fedora_release=""
    local version=""
    local output_dir=${PWD}

    while getopts "r:f:v:o:" OPTION
    do
        case $OPTION in
            r)
                ovirt_release_rpm=$OPTARG
                ;;
            f)
                fedora_release=$OPTARG
                ;;
            v)
                version=$OPTARG
                ;;
            o)
                output_dir=$OPTARG
                ;;
        esac
    done

    if [[ -n ${ovirt_release_rpm} && -n ${fedora_release} ]]; then
        echo "Using ovirt-release-rpm: ${ovirt_release_rpm}"
        echo "Using Fedora: ${fedora_release}"
        setup_repos "${ovirt_release_rpm}" "${fedora_release}"
        workdir=$(mktemp -dp /var/tmp)
        chmod 755 ${workdir}
        setup_cosa ${workdir}
        handle_overrides ${workdir}
        pushd ${workdir}
        cosa init --force /dev/null
        find .
        cosa fetch
        cosa build ostree
        cosa buildextend-metal
        cosa buildextend-installer
        verstr="${version}-$(date +%Y%m%d%H).fc${fedora_release}"
        iso="ovirt-node-coreos-installer-${verstr}.iso"
        img="ovirt-node-coreos-metal-${verstr}.raw.gz"
        ostree="ovirt-node-coreos-ostree-commit-${verstr}.tar"
        find . -name "*.raw" -exec gzip {} \;
        mkdir -p ${output_dir}
        find . -name "*.iso" -exec mv {} ${output_dir}/${iso} \;
        find . -name "*.raw.gz" -exec mv {} ${output_dir}/${img} \;
        find . -name "ostree-commit.tar" -exec mv {} ${output_dir}/${ostree} \;
        popd
        rm -rf ${workdir}
    else
        echo "Usage: $0 -r <ovirt-release-rpm> -v <fedora release> -o <dir>"
    fi
}

main "$@"
