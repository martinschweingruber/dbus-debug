#!/bin/bash

# Copyright © 2015-2016 Collabora Ltd.
#
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation files
# (the "Software"), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software,
# and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
# BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
# ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -euo pipefail
set -x

NULL=

# ci_distro:
# OS distribution in which we are testing
# Typical values: ubuntu, debian; maybe fedora in future
: "${ci_distro:=ubuntu}"

# ci_docker:
# If non-empty, this is the name of a Docker image. ci-install.sh will
# fetch it with "docker pull" and use it as a base for a new Docker image
# named "ci-image" in which we will do our testing.
: "${ci_docker:=}"

# ci_host:
# Either "native", or an Autoconf --host argument to cross-compile
# the package
: "${ci_host:=native}"

# ci_in_docker:
# Used internally by ci-install.sh. If yes, we are inside the Docker image
# (ci_docker is empty in this case).
: "${ci_in_docker:=no}"

# ci_local_packages:
# prefer local packages instead of distribution
: "${ci_local_packages:=yes}"

# ci_suite:
# OS suite (release, branch) in which we are testing.
# Typical values for ci_distro=debian: sid, jessie
# Typical values for ci_distro=fedora might be 25, rawhide
: "${ci_suite:=xenial}"

# ci_variant:
# One of debug, reduced, legacy, production
: "${ci_variant:=production}"

if [ $(id -u) = 0 ]; then
    sudo=
else
    sudo=sudo
fi

if [ -n "$ci_docker" ]; then
    sed \
        -e "s/@ci_distro@/${ci_distro}/" \
        -e "s/@ci_docker@/${ci_docker}/" \
        -e "s/@ci_suite@/${ci_suite}/" \
        < tools/ci-Dockerfile.in > Dockerfile
    exec docker build -t ci-image .
fi

case "$ci_distro" in
    (debian|ubuntu)
        # Don't ask questions, just do it
        sudo="$sudo env DEBIAN_FRONTEND=noninteractive"

        # Debian Docker images use httpredir.debian.org but it seems to be
        # unreliable; use a CDN instead
        $sudo sed -i -e 's/httpredir\.debian\.org/deb.debian.org/g' \
            /etc/apt/sources.list

        case "$ci_suite" in
            (xenial)
                # Ubuntu 16.04 didn't have the wine32, wine64 packages
                wine32=wine:i386
                wine64=wine:amd64
                ;;
            (*)
                wine32=wine32
                wine64=wine64
                ;;
        esac

        case "$ci_host" in
            (i686-w64-mingw32)
                $sudo dpkg --add-architecture i386
                ;;
            (x86_64-w64-mingw32)
                # assume the host or container is x86_64 already
                ;;
        esac

        $sudo apt-get -qq -y update
        packages=()

        case "$ci_host" in
            (i686-w64-mingw32)
                packages=(
                    "${packages[@]}"
                    binutils-mingw-w64-i686
                    g++-mingw-w64-i686
                    $wine32 wine
                )
                ;;
            (x86_64-w64-mingw32)
                packages=(
                    "${packages[@]}"
                    binutils-mingw-w64-x86-64
                    g++-mingw-w64-x86-64
                    $wine64 wine
                )
                ;;
        esac

        if [ "$ci_host/$ci_variant/$ci_suite" = "native/production/buster" ]; then
            packages=(
                "${packages[@]}"
                qttools5-dev-tools
                qt5-default
            )
        fi

        packages=(
            "${packages[@]}"
            adduser
            autoconf-archive
            automake
            autotools-dev
            ccache
            cmake
            debhelper
            dh-autoreconf
            dh-exec
            docbook-xml
            docbook-xsl
            doxygen
            dpkg-dev
            g++
            gcc
            gnome-desktop-testing
            libapparmor-dev
            libaudit-dev
            libcap-ng-dev
            libexpat-dev
            libglib2.0-dev
            libselinux1-dev
            libsystemd-dev
            libx11-dev
            sudo
            valgrind
            wget
            xauth
            xmlto
            xsltproc
            xvfb
        )

        case "$ci_suite" in
            (stretch)
                # Debian 9 'stretch' didn't have the ducktype package
                ;;

            (*)
                # assume Ubuntu 18.04 'bionic', Debian 10 'buster' or newer
                packages=(
                    "${packages[@]}"
                    ducktype yelp-tools
                )
                ;;
        esac

        $sudo apt-get -qq -y --no-install-recommends install "${packages[@]}"

        if [ "$ci_in_docker" = yes ]; then
            # Add the user that we will use to do the build inside the
            # Docker container, and let them use sudo
            adduser --disabled-password --gecos "" user
            echo "user ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/nopasswd
            chmod 0440 /etc/sudoers.d/nopasswd
        fi

        # manual package setup
        case "$ci_suite" in
            (jessie|xenial)
                # autoconf-archive in Debian 8 and Ubuntu 16.04 is too old,
                # use the one from Debian 9 instead
                wget http://deb.debian.org/debian/pool/main/a/autoconf-archive/autoconf-archive_20160916-1_all.deb
                $sudo dpkg -i autoconf-archive_*_all.deb
                rm autoconf-archive_*_all.deb
                ;;
        esac

        # Make sure we have a messagebus user, even if the dbus package
        # isn't installed
        $sudo adduser --system --quiet --home /nonexistent --no-create-home \
            --disabled-password --group messagebus
        ;;

    (*)
        echo "Don't know how to set up ${ci_distro}" >&2
        exit 1
        ;;
esac

if [ "$ci_local_packages" = yes ]; then
    case "$ci_host" in
        (*-w64-mingw32)
            mirror=http://repo.msys2.org/mingw/${ci_host%%-*}
            dep_prefix=$(pwd)/${ci_host}-prefix
            install -d "${dep_prefix}"
            packages=(
                bzip2-1.0.8-1
                expat-2.2.9-1
                gcc-libs-9.3.0-2
                gettext-0.19.8.1-8
                glib2-2.64.2-1
                iconv-1.16-1
                libffi-3.3-1
                libiconv-1.16-1
                libwinpthread-git-8.0.0.5814.9dbf4cc1-1
                pcre-8.44-1
                zlib-1.2.11-7
            )
            for pkg in "${packages[@]}" ; do
                wget ${mirror}/mingw-w64-${ci_host%%-*}-${pkg}-any.pkg.tar.xz
                tar -C ${dep_prefix} --strip-components=1 -xvf mingw-w64-${ci_host%%-*}-${pkg}-any.pkg.tar.xz
            done

            # limit access rights
            if [ "$ci_in_docker" = yes ]; then
                chown -R user "${dep_prefix}"
            fi
            ;;
    esac
fi

# vim:set sw=4 sts=4 et:
