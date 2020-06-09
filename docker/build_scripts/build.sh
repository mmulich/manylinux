#!/bin/bash
# Top-level build script called from Dockerfile

# Stop at any error, show all commands
set -ex

# Set build environment variables
MY_DIR=$(dirname "${BASH_SOURCE[0]}")
. $MY_DIR/build_env.sh

# Dependencies for compiling Python that we want to remove from
# the final image after compiling Python
PYTHON_COMPILE_DEPS="build-essential zlib1g-dev libncurses5-dev libgdbm-dev libnss3-dev libssl-dev libsqlite3-dev libreadline-dev libffi-dev curl libbz2-dev"

# Libraries that are allowed as part of the manylinux2010 profile
# Extract from PEP: https://www.python.org/dev/peps/pep-0571/#the-manylinux2010-policy
#
# On Debian-based systems, these libraries are provided by the packages:
#
# Package 	Libraries
# libc6 	libdl.so.2, libresolv.so.2, librt.so.1, libc.so.6, libpthread.so.0, libm.so.6, libutil.so.1, libnsl.so.1
# libgcc1 	libgcc_s.so.1
# libgl1 	libGL.so.1
# libglib2.0-0 	libgobject-2.0.so.0, libgthread-2.0.so.0, libglib-2.0.so.0
# libice6 	libICE.so.6
# libsm6 	libSM.so.6
# libstdc++6 	libstdc++.so.6
# libx11-6 	libX11.so.6
# libxext6 	libXext.so.6
# libxrender1 	libXrender.so.1
#
# Install development packages
MANYLINUX2014_DEPS="libc6 libgcc1 libgl1 libglib2.0-0 libice6 libsm6 libstdc++6 libx11-6 libxext6 libxrender1"

# Get build utilities
source $MY_DIR/build_utils.sh

apt-get update


# Development tools and libraries
#
# m4 - dep of autoconf
#
apt-get install -y \
    m4 \
    ${PYTHON_COMPILE_DEPS}

# Build an OpenSSL for Pythons. We'll delete this at the end.
build_openssl $OPENSSL_ROOT $OPENSSL_HASH

# Install newest autoconf
build_autoconf $AUTOCONF_ROOT $AUTOCONF_HASH
autoconf --version

# Install newest automake
build_automake $AUTOMAKE_ROOT $AUTOMAKE_HASH
automake --version

# Install newest libtool
build_libtool $LIBTOOL_ROOT $LIBTOOL_HASH
libtool --version

# Install a more recent SQLite3
curl -fsSLO $SQLITE_AUTOCONF_DOWNLOAD_URL/$SQLITE_AUTOCONF_VERSION.tar.gz
check_sha256sum $SQLITE_AUTOCONF_VERSION.tar.gz $SQLITE_AUTOCONF_HASH
tar xfz $SQLITE_AUTOCONF_VERSION.tar.gz
cd $SQLITE_AUTOCONF_VERSION
do_standard_install
cd ..
rm -rf $SQLITE_AUTOCONF_VERSION*
rm /usr/local/lib/libsqlite3.a

# Install libcrypt.so.1 and libcrypt.so.2
build_libxcrypt "$LIBXCRYPT_DOWNLOAD_URL" "$LIBXCRYPT_VERSION" "$LIBXCRYPT_HASH"

# Compile the latest Python releases.
# (In order to have a proper SSL module, Python is compiled
# against a recent openssl [see env vars above], which is linked
# statically.
mkdir -p /opt/python
build_cpythons $CPYTHON_VERSIONS

PY37_BIN=/opt/python/cp37-cp37m/bin

# Install certifi and auditwheel
$PY37_BIN/pip install --require-hashes -r $MY_DIR/py37-requirements.txt

# Our openssl doesn't know how to find the system CA trust store
#   (https://github.com/pypa/manylinux/issues/53)
# And it's not clear how up-to-date that is anyway
# So let's just use the same one pip and everyone uses
ln -s $($PY37_BIN/python -c 'import certifi; print(certifi.where())') \
      /opt/_internal/certs.pem
# If you modify this line you also have to modify the versions in the
# Dockerfiles:
export SSL_CERT_FILE=/opt/_internal/certs.pem

# Now we can delete our built OpenSSL headers/static libs since we've linked everything we need
rm -rf /usr/local/ssl

# Install patchelf (latest with unreleased bug fixes) and apply our patches
build_patchelf $PATCHELF_VERSION $PATCHELF_HASH

ln -s $PY37_BIN/auditwheel /usr/local/bin/auditwheel

# # Clean up development headers and other unnecessary stuff for
# # final image
# apt-get purge -y
#     avahi \
#     bitstream-vera-fonts \
#     freetype \
#     gettext \
#     gtk2 \
#     hicolor-icon-theme \
#     libX11 \
#     ${PYTHON_COMPILE_DEPS} > /dev/null 2>&1
# apt-get autoremove
apt-get install -y ${MANYLINUX2014_DEPS}
# yum -y clean all > /dev/null 2>&1
# yum list installed

# we don't need libpython*.a, and they're many megabytes
find /opt/_internal -name '*.a' -print0 | xargs -0 rm -f

# Strip what we can -- and ignore errors, because this just attempts to strip
# *everything*, including non-ELF files:
find /opt/_internal -type f -print0 \
    | xargs -0 -n1 strip --strip-unneeded 2>/dev/null || true
find /usr/local -type f -print0 \
    | xargs -0 -n1 strip --strip-unneeded 2>/dev/null || true

for PYTHON in /opt/python/*/bin/python; do
    # Smoke test to make sure that our Pythons work, and do indeed detect as
    # being manylinux compatible:
    $PYTHON $MY_DIR/manylinux-check.py
    # Make sure that SSL cert checking works
    $PYTHON $MY_DIR/ssl-check.py
done

# We do not need the Python test suites, or indeed the precompiled .pyc and
# .pyo files. Partially cribbed from:
#    https://github.com/docker-library/python/blob/master/3.4/slim/Dockerfile
find /opt/_internal -depth \
     \( -type d -a -name test -o -name tests \) \
  -o \( -type f -a -name '*.pyc' -o -name '*.pyo' \) | xargs rm -rf

# Fix libc headers to remain compatible with C99 compilers.
find /usr/include/ -type f -exec sed -i 's/\bextern _*inline_*\b/extern __inline __attribute__ ((__gnu_inline__))/g' {} +

# # if we updated glibc, we need to strip locales again...
# localedef --list-archive | grep -v -i ^en_US.utf8 | xargs localedef --delete-from-archive
# mv -f /usr/lib/locale/locale-archive /usr/lib/locale/locale-archive.tmpl
# build-locale-archive
# find /usr/share/locale -mindepth 1 -maxdepth 1 -not \( -name 'en*' -or -name 'locale.alias' \) | xargs rm -rf
# find /usr/local/share/locale -mindepth 1 -maxdepth 1 -not \( -name 'en*' -or -name 'locale.alias' \) | xargs rm -rf
# rm -rf /usr/local/share/man
