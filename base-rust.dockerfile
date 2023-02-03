################################################################################
# For now it is use as a base of the CI image for the Rust repos eg `api_circuits` and `integritee-node`
# (`integritee-worker` requires SGX so we use integritee's images)

# podman build -f base-rust.dockerfile -t ghcr.io/interstellar-network/ci-images/base-rust:dev --build-arg BASE_IMAGE=rust:1.67 .
# to publish:
# podman tag ghcr.io/interstellar-network/ci-images/base-rust:dev ghcr.io/interstellar-network/ci-images/base-rust:vXXX
# podman push ghcr.io/interstellar-network/ci-images/base-rust:vXXX

ARG BASE_IMAGE=rust:1.67

FROM $BASE_IMAGE as builder

WORKDIR /usr/src/app

# DEBIAN_FRONTEND needed to stop prompt for timezone
# ca-certificates: recommended by wget; else we get eg "ERROR: cannot verify github.com's certificate, issued by 'CN=DigiCert TLS Hybrid ECC SHA384 2020 CA1,O=DigiCert Inc,C=US'"
# sudo: needed only b/c that way we can use the same CI workflows when using this image, and when running directly on ubuntu-latest(which uses passwordless sudo)
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates curl unzip xz-utils git sudo \
    && rm -rf /var/lib/apt/lists/*

# https://stackoverflow.com/questions/323957/how-do-i-edit-etc-sudoers-from-a-script
RUN bash -c 'echo "root ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/99_passwordless_root' && \
    visudo -c -q -f /etc/sudoers.d/99_passwordless_root && \
    sudo echo test

# prereq: install CMake
ENV PATH=$PATH:/opt/cmake/bin/
# remove cmake-gui: 29MB
# remove ccmake: 13MB
# remove doc: 31MB
# remove man: 3MB
RUN export version=3.25.2 && \
    wget https://github.com/Kitware/CMake/releases/download/v$version/cmake-$version-linux-x86_64.sh && \
    chmod +x cmake-$version-linux-x86_64.sh && \
    mkdir /opt/cmake/ && \
    ./cmake-$version-linux-x86_64.sh --skip-license --prefix=/opt/cmake/ && \
    rm cmake-*.sh && \
    rm -rf /opt/cmake/bin/cmake-gui /opt/cmake/bin/ccmake /opt/cmake/doc /opt/cmake/man && \
    cmake -version

# prereq: install Ninja (ninja-build)
RUN wget https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip && \
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

# Install mold(linker)
# Set it as default(ie replace ld) b/c Rust tends to NOT correctly detect
# RUSTFLAGS and that force things to recompile from scratch
#
# https://github.com/rui314/setup-mold/blob/main/action.yml
# version=$(wget -q -O- https://api.github.com/repos/rui314/mold/releases/latest | jq -r .tag_name | sed 's/^v//'); true
RUN export version=1.10.1 && \
    wget -O- https://github.com/rui314/mold/releases/download/v$version/mold-$version-$(uname -m)-linux.tar.gz | tar -C /usr/local --strip-components=1 -xzf - && \
    sudo chmod +x /usr/local/bin/mold && \
    ln -sf /usr/local/bin/mold $(realpath /usr/bin/ld) && \
    ld --version && \
    mold --version