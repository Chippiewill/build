#!/bin/bash -ex

# We assume "repo" has already run, placing the build git as
# ${WORKSPACE}/cbbuild and voltron as ${WORKSPACE}/voltron.
#
# Required job parameters (expected to be in environment):
# DISTRO  - Distribution name (eg., "ubuntu12.04", "debian7", "centos6", "macos")
#     This will be used to determine the pacakging format (.deb, .rpm, or .zip).
# VERSION - in the form x.x.x
# EDITION - "enterprise" or "community"
# BLD_NUM - xxxx
#
# (At some point these will instead be read from the manifest.)
#

usage() {
    echo "Usage: $0 [ ubuntu12.04 | debian7 | centos6 | ... ] <VERSION> <EDITION> <BLD_NUM>"
    exit 5
}

if [ "$#" -ne 4 ]
then
    usage
fi

DISTRO=$1
case "$DISTRO" in
    centos6)
        PKG=rpm
        FLAVOR=redhat6
        ;;
    centos7)
        PKG=rpm
        FLAVOR=redhat7
        ;;
    *suse*)
        PKG=rpm
        FLAVOR=suse
        ;;
    debian*|ubuntu*)
        PKG=deb
        ;;
    macos)
        PKG=mac
        ;;
    nopkg)
        echo "Skipping packaging step"
        ;;
    *)
        usage
        ;;
esac

export VERSION=$2
export EDITION=$3
export BLD_NUM=$4

# Compute WORKSPACE, if not in environment
if [ -z "${WORKSPACE}" ]
then
    WORKSPACE="$( cd "$(dirname "$0")"/../../../.. ; pwd -P )"
fi

# Step 0: Derived values and cleanup. (Some of these are RPM- or
# DEB-specific, but will safely do nothing on other systems.)
export PRODUCT_VERSION=${VERSION}-${BLD_NUM}
rm -f *.rpm *.deb *.zip
rm -rf ~/rpmbuild
rm -rf ${WORKSPACE}/voltron/build/deb
rm -rf /opt/couchbase/*
find goproj godeps -name \*.a -print0 | xargs -0 rm -f

# Step 1: Build Couchbase Server itself, using CMake.

echo
echo =============== 1. Build Couchbase Server using CMake
echo
cd ${WORKSPACE}
mkdir -p build
cd build
if [ "${EDITION}" = "enterprise" ]
then
    BUILD_ENTERPRISE=TRUE
else
    BUILD_ENTERPRISE=FALSE
fi
cmake -D CMAKE_INSTALL_PREFIX=/opt/couchbase \
      -D CMAKE_PREFIX_PATH=/opt/couchbase \
      -D CMAKE_BUILD_TYPE=RelWithDebInfo \
      -D PRODUCT_VERSION=${PRODUCT_VERSION} \
      -D BUILD_ENTERPRISE=${BUILD_ENTERPRISE} \
      -D CB_DOWNLOAD_DEPS=1 \
      -D SNAPPY_OPTION=Disable \
      ${EXTRA_CMAKE_OPTIONS} \
      ..
make -j8 install || (
    echo; echo; echo -------------
    echo make -j8 failed - re-running with no -j8 to hopefully get better debug output
    echo -------------; echo; echo
    make
    exit 2
)

# couchdbx-app on MacOS depends on this:
rm -f ${WORKSPACE}/install && ln -s /opt/couchbase ${WORKSPACE}/install

if [ "${DISTRO}" = "nopkg" ]
then
    echo "Skipping packaging as requested; all done!"
    exit 0
fi

# Step 2: Create installer, using Voltron.  Goal is to incorporate the
# "build-filter" and "overlay" steps here or into server-rpm/deb.rb, so
# we can completely drop voltron's Makefile.

echo
echo =============== 2. Building installation package
echo

# Pre-clean all unnecessary files
cd ${WORKSPACE}
ruby voltron/cleanup.rb /opt/couchbase

# We still need to create this for voltron's "overlay" step, if it's not
# already there.
if [ ! -e "manifest.xml" ]
then
  repo manifest -r > manifest.xml
fi

# Tweak install directory in Voltron-magic fashion
cd ${WORKSPACE}/voltron
make PRODUCT_VERSION=${PRODUCT_VERSION} LICENSE=LICENSE-${EDITION}.txt \
     BUILD_DIR=${WORKSPACE} \
     TOPDIR=${WORKSPACE}/voltron build-filter overlay
if [ -d "server-overlay-${PKG}" ]
then
    # common to all distros
    cp -R server-overlay-${PKG}/common/* /opt/couchbase

    if [ "${PKG}" = "rpm" ]
    then
        cp -R server-overlay-${PKG}/${FLAVOR}/* /opt/couchbase
        cp server-rpm.${FLAVOR}.spec.tmpl server-rpm.spec.tmpl
        cp moxi-rpm.${FLAVOR}.spec.tmpl moxi-rpm.spec.tmpl
    fi
fi

cxxlib_needed="debian7|suse11|ubuntu12"
if [[ "$DISTRO" =~ $cxxlib_needed ]]
then
    libstdcpp=`g++ --print-file-name=libstdc++.so`
    libstdcppname=`basename "$libstdcpp"`
    cp -p "$libstdcpp" "/opt/couchbase/lib/$libstdcppname"
    ln -s "$libstdcppname" "/opt/couchbase/lib/${libstdcppname}.6"
fi

# libnuma.so is required on Linux platforms (so we can control NUMA
# allocation policy).
if [ "${PKG}" != "mac" ]
then
    libnuma="libnuma.so.1"
    libnuma_path=$(g++ --print-file-name=${libnuma})
    cp -p ${libnuma_path} /opt/couchbase/lib/${libnuma}
fi

# Determine flavor of OpenSSL required
openssl098_needed="suse11"
if [[ "$DISTRO" =~ $openssl098_needed ]]
then
    OPENSSL_VER=0.9.8
else
    OPENSSL_VER=1.0.0
fi

# The "product name" is couchbase-server for Enterprise and
# couchbase-server-community for Community, to keep them
# distinguished in deb/rpm repositories.
if [ "${EDITION}" = "enterprise" ]
then
    PRODUCT=couchbase-server
else
    PRODUCT=couchbase-server-community
fi

# Execute platform-specific packaging step
export LD_LIBRARY_PATH=/opt/couchbase/lib
./server-${PKG}.rb /opt/couchbase ${PRODUCT} couchbase server ${OPENSSL_VER}

if [ "${PKG}" = "mac" ]
then
    # Xcode leaves stale precompiled headers and expects us to clean them up
    find /var/folders -type d -name SharedPrecompiledHeaders | xargs rm -rf

    cd ${WORKSPACE}/couchdbx-app
    LICENSE=LICENSE-${EDITION}.txt make couchbase-server-zip
    cd ${WORKSPACE}
fi

# Move final installation package to top of workspace, and set up
# trigger.properties for downstream jobs
case "$PKG" in
    rpm)
        ARCHITECTURE=x86_64
        INSTALLER_FILENAME=couchbase-server-${EDITION}-${VERSION}-${BLD_NUM}-${DISTRO}.${ARCHITECTURE}.rpm
        cp ~/rpmbuild/RPMS/x86_64/${PRODUCT}-[0-9]*.rpm ${WORKSPACE}/${INSTALLER_FILENAME}

        # Debuginfo package. Older versions of RHEL name the it "*-debug-*.rpm";
        # newer ones and SuSE use "-debuginfo-*.rpm".
        # Scan for both and move to correct final name.
        DBG_PREFIX="${HOME}/rpmbuild/RPMS/x86_64/${PRODUCT}"
        DEBUG=""
        if ls ${DBG_PREFIX}-debug-*.rpm > /dev/null 2>&1;
        then
          DEBUG=debug
        elif ls ${DBG_PREFIX}-debuginfo-*.rpm > /dev/null 2>&1;
        then
          DEBUG=debuginfo
        else
          echo "Warning: No ${PRODUCT}-{debug,debuginfo}-*.rpm package found; skipping copy."
        fi
        if [ -n "$DEBUG" ]
        then
          cp ${DBG_PREFIX}-${DEBUG}-*.rpm \
             ${WORKSPACE}/couchbase-server-${EDITION}-${DEBUG}-${VERSION}-${BLD_NUM}-${DISTRO}.${ARCHITECTURE}.rpm
        fi
        ;;
    deb)
        ARCHITECTURE=amd64
        INSTALLER_FILENAME=couchbase-server-${EDITION}_${VERSION}-${BLD_NUM}-${DISTRO}_${ARCHITECTURE}.deb
        DBG_FILENAME=couchbase-server-${EDITION}-dbg_${VERSION}-${BLD_NUM}-${DISTRO}_${ARCHITECTURE}.deb
        cp build/deb/${PRODUCT}_*.deb ${WORKSPACE}/${INSTALLER_FILENAME}
        cp build/deb/${PRODUCT}-dbg_*.deb ${WORKSPACE}/${DBG_FILENAME}
        ;;
    mac)
        ARCHITECTURE=x86_64
        INSTALLER_FILENAME=couchbase-server-${EDITION}_${VERSION}-${BLD_NUM}-${DISTRO}_${ARCHITECTURE}.zip
        cp couchdbx-app/build/Release/*.zip ${WORKSPACE}/${INSTALLER_FILENAME}
        ;;
esac

# Back to the top
cd ${WORKSPACE}

# Support for Oracle Enterprise Linux. If we're building Centos 6, make
# an exact copy with an oel6 filename.
case "$DISTRO" in
    centos6)
        for rpm in *.rpm
        do
            cp ${rpm} ${rpm//centos/oel}
        done
        ;;
esac

echo Creating trigger.properties...
cat <<EOF > trigger.properties
ARCHITECTURE=${ARCHITECTURE}
PLATFORM=${DISTRO}
INSTALLER_FILENAME=${INSTALLER_FILENAME}
BUILD_WORKSPACE=${WORKSPACE}
EOF

echo
echo =============== DONE!
echo
