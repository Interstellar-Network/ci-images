################################################################################
# CI image use as "container:" for the the CI of lib_circuits and lib_garble
# For now it is also used as a base of the CI image for the Rust repos api_circuits
# and api_garble b/c they compile the lib_ from source.

# podman build -f ci-base-cpp.dockerfile -t ci-base-cpp:dev .
# podman tag ci-base-cpp:dev ghcr.io/interstellar-network/ci-images/ci-base-cpp:dev

FROM ubuntu:20.04 as builder

WORKDIR /usr/src/app

# DEBIAN_FRONTEND needed to stop prompt for timezone
# ca-certificates: recommended by wget; else we get eg "ERROR: cannot verify github.com's certificate, issued by 'CN=DigiCert TLS Hybrid ECC SHA384 2020 CA1,O=DigiCert Inc,C=US'"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates curl unzip xz-utils git \
    && rm -rf /var/lib/apt/lists/*

# prereq: install CMake
ENV PATH=$PATH:/opt/cmake/bin/
RUN wget https://github.com/Kitware/CMake/releases/download/v3.22.3/cmake-3.22.3-linux-x86_64.sh && \
    chmod +x cmake-3.22.3-linux-x86_64.sh && \
    mkdir /opt/cmake/ && \
    ./cmake-3.22.3-linux-x86_64.sh --skip-license --prefix=/opt/cmake/ && \
    rm cmake-*.sh && \
    cmake -version

# prereq: install Ninja (ninja-build)
RUN wget https://github.com/ninja-build/ninja/releases/download/v1.10.2/ninja-linux.zip && \
    unzip ninja-linux.zip -d /usr/local/bin/ && \
    rm ninja-linux.zip && \
    ninja --version

# prereq: install clang
# https://baykara.medium.com/installing-clang-10-in-a-docker-container-4c24a4538af2
# ENV LLVM_VERSION clang+llvm-13.0.1-x86_64-linux-gnu-ubuntu-18.04
# RUN wget https://github.com/llvm/llvm-project/releases/download/llvmorg-13.0.1/$LLVM_VERSION.tar.xz && \
#     mkdir -p /opt/$LLVM_VERSION && \
#     tar -xf $LLVM_VERSION.tar.xz -C /opt/$LLVM_VERSION && \
#     mkdir -p /opt/llvm && \
#     mv /opt/$LLVM_VERSION/$LLVM_VERSION/* /opt/llvm && \
#     rm $LLVM_VERSION.tar.xz
# cf https://apt.llvm.org/
# NOTE in llvm.sh:
# echo "You are missing some tools this script requires: ${missing_binaries[@]}"
# echo "(hint: apt install lsb-release wget software-properties-common)"
#
# The following additional packages will be installed:
#   dbus dbus-user-session dconf-gsettings-backend dconf-service
#   distro-info-data gir1.2-glib-2.0 gir1.2-packagekitglib-1.0 glib-networking
#   glib-networking-common glib-networking-services gpg gpgconf
#   gsettings-desktop-schemas iso-codes libapparmor1 libappstream4 libargon2-1
#   libassuan0 libcap2 libcap2-bin libcryptsetup12 libdbus-1-3 libdconf1
#   libdevmapper1.02.1 libelf1 libgirepository-1.0-1 libglib2.0-0 libglib2.0-bin
#   libglib2.0-data libgstreamer1.0-0 libicu66 libip4tc2 libjson-c4 libkmod2
#   liblmdb0 libmpdec2 libpackagekit-glib2-18 libpam-systemd libpolkit-agent-1-0
#   libpolkit-gobject-1-0 libproxy1v5 libpython3-stdlib libpython3.8-minimal
#   libpython3.8-stdlib libreadline8 libsoup2.4-1 libstemmer0d libxml2
#   libyaml-0-2 mime-support packagekit policykit-1 python-apt-common python3
#   python3-apt python3-certifi python3-chardet python3-dbus python3-gi
#   python3-idna python3-minimal python3-pkg-resources python3-requests
#   python3-requests-unixsocket python3-six python3-software-properties
#   python3-urllib3 python3.8 python3.8-minimal readline-common systemd
#   systemd-sysv systemd-timesyncd tzdata
#
# gpg-agent: failed to start agent '/usr/bin/gpg-agent': No such file or directory
# NOTE: this is a 900+MB layer...
# and as GH Action DOES NOT cache pulled images, the step "Initialize containers" takes 20+s
# RUN apt-get update && apt-get install -y --no-install-recommends \
#     lsb-release software-properties-common \
#     gpg-agent \
#     && rm -rf /var/lib/apt/lists/*  && \
#     wget https://apt.llvm.org/llvm.sh && \
#     chmod +x llvm.sh && \
#     ./llvm.sh 13 && \
#     rm -rf /var/lib/apt/lists/* && \
#     rm llvm.sh && \
#     update-alternatives --install /usr/bin/clang clang /usr/bin/clang-13 100 && \
#     update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-13 100 && \
#     clang --version
#
# With this layer is 208.2MB
RUN apt-get update && apt-get install -y --no-install-recommends \
    # build-essential would work too, but:
    # - install gcc 9 instead of 10
    # - also dep on make, and dpkg-XXX
    # NOTE: g++ dep on gcc-N so this is fine, also libc-dev and libstdc++-10-dev
    g++-10 \
    && rm -rf /var/lib/apt/lists/* && \
    update-alternatives --install /usr/bin/cc cc /usr/bin/gcc-10 100 && \
    update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 100 && \
    update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-10 100 && \
    cc --version && \
    gcc --version && \
    g++ --version

# Install Conan from deb
RUN wget https://github.com/conan-io/conan/releases/latest/download/conan-ubuntu-64.deb -O /tmp/conan.deb && \
    apt-get install -y --no-install-recommends /tmp/conan.deb && \
    rm -rf /var/lib/apt/lists/* && \
    rm /tmp/conan.deb && \
    conan --version
    # TODO?
    # conan profile new default --detect
    # conan profile update settings.compiler=gcc default
    # conan profile update settings.compiler.libcxx=libstdc++11 default

# Install CCache from prebuilt
RUN wget https://github.com/Interstellar-Network/gh-actions/releases/download/ccache-4.6/ccache -O /usr/local/bin/ccache && \
    chmod +x /usr/local/bin/ccache && \
    ccache --show-config
