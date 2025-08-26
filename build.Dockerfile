################################################################################
#
# We use this b/c we want two versions of this Dockerfile:
# docker build -t ci-base-dev -f build.Dockerfile --target default --build-arg "SSH_KEY=$YOUR_SSH_KEY" .
# docker build -t ci-base-dev-sgx -f build.Dockerfile --target sgx --build-arg "SSH_KEY=$YOUR_SSH_KEY" .
# We need `--target default` that way we have a proper multi stage build.
# We MUST nake sure the "default" PATH is NOT polluted with SGX else in eg the `node` we get:
#   "/opt/intel/sgxsdk/binutils/ld: skipping incompatible /lib/x86_64-linux-gnu/libmvec.so.1 when searching for /lib/x86_64-linux-gnu/libmvec.so.1"
ARG BASE_IMAGE=ubuntu:24.04

FROM $BASE_IMAGE as base

# DEBIAN_FRONTEND needed to stop prompt for timezone
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ca-certificates: recommended by wget; else we get eg "ERROR: cannot verify github.com's certificate, issued by 'CN=DigiCert TLS Hybrid ECC SHA384 2020 CA1,O=DigiCert Inc,C=US'"
# sudo: needed only b/c that way we can use the same CI workflows when using this image, and when running directly on ubuntu-latest(which uses passwordless sudo)
RUN apt-get update && apt-get install -y --no-install-recommends \
    wget ca-certificates curl unzip xz-utils git ssh sudo vim \
    cmake ninja-build build-essential \
    && rm -rf /var/lib/apt/lists/*

# https://stackoverflow.com/questions/323957/how-do-i-edit-etc-sudoers-from-a-script
RUN bash -c 'echo "root ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/99_passwordless_root' && \
    visudo -c -q -f /etc/sudoers.d/99_passwordless_root && \
    sudo echo test

###############################################################################
# --- Create a non-root user to run the application ---
# Create a group and user with specific IDs. Using a fixed ID > 1000 is good practice.
RUN groupadd --gid 1001 myuser && \
    useradd --uid 1001 --gid 1001 --shell /bin/bash --create-home myuser

# Add the new 'myuser' to the 'sudo' group and grant it passwordless sudo.
# This allows the user to perform administrative tasks needed during the build.
RUN usermod -aG sudo myuser && \
    echo "myuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99_passwordless_myuser

# Set the HOME environment variable for all subsequent users
ENV HOME=/home/myuser

# --- Copy your application files ---
# Set the work directory to the user's home
WORKDIR ${HOME}

# --- Switch to the non-root user ---
# All subsequent commands (RUN, CMD, ENTRYPOINT) will run as `myuser`.
USER myuser

###############################################################################
# Store SSH KEY
# NOTE this MUST be for the new User, so DO NOT move it at the top!
# SSH KEY of a user with access to all the Org's repos
ARG SSH_KEY

RUN test -n "$SSH_KEY" || (echo "SSH_KEY not set" && false)
RUN mkdir -p ~/.ssh \
    && echo "$SSH_KEY" >> ~/.ssh/id_ed25519 \
    && chmod 600 ~/.ssh/id_ed25519 

# Add GitHub to known hosts to avoid a prompt
RUN mkdir -p ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null \
    && cat /home/myuser/.ssh/id_ed25519 \
    && git ls-remote git@github.com:Interstellar-Network/pallets-internal.git HEAD
# This returns 1 even on success b/c no shell access, so not good for this
# && ssh -T git@github.com

###############################################################################
# RUST specifics
# mkdir to avoid permission in "client images"(eg api-circuits etc)
# Caused by:
#   failed to create directory `/home/myuser/.cargo/git/checkouts/lib_circuits-internal-4466348c63f09e9a`
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y ;\
    cat $HOME/.cargo/env && \
    mkdir -p ${HOME}/.cargo/git/checkouts -p ${HOME}/.cargo/registry/src

# https://doc.rust-lang.org/cargo/reference/config.html#netgit-fetch-with-cli
# Needed to use private GitHub repo as `Cargo` git dependencies
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

# equivalent to `. "$HOME/.cargo/env"`
ENV PATH="${HOME}/.cargo/bin:${PATH}"

# Install mold(linker)
# Set it as default(ie replace ld) b/c Rust tends to NOT correctly detect
# RUSTFLAGS and that force things to recompile from scratch
#
# https://github.com/rui314/setup-mold/blob/main/action.yml
# version=$(wget -q -O- https://api.github.com/repos/rui314/mold/releases/latest | jq -r .tag_name | sed 's/^v//'); true
RUN export version=2.40.1 && \
    cd /tmp && \
    wget -O- https://github.com/rui314/mold/releases/download/v$version/mold-$version-$(uname -m)-linux.tar.gz | sudo tar -C /usr/local --strip-components=1 -xzf - && \
    sudo chmod +x /usr/local/bin/mold && \
    sudo ln -sf /usr/local/bin/mold $(realpath /usr/bin/ld)

###############################################################################
ARG SCCACHE_VERSION=0.10.0
# RUN cargo install --version ${SCCACHE_VERSION} sccache --locked
RUN mkdir /tmp/sscache && \
        cd /tmp/sscache && \
        wget -c https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz -O - | tar -xz --strip-components 1 && \
        chmod +x sccache && \
        sudo mv sccache /usr/local/bin/sccache && \
        sccache --version

ENV SCCACHE_CACHE_SIZE="20G"
ENV SCCACHE_DIR=$HOME/.cache/sccache
ENV RUSTC_WRAPPER="/usr/local/bin/sccache"

###############################################################################
# REPO specifics: lib_circuits-internal, but it is a dependency of all the repo (sort of)
# so add that to the "base image" here
RUN sudo apt-get update && \
        cd /tmp && \
	wget https://github.com/Interstellar-Network/yosys/releases/download/yosys-0.29/yosys-0.1.29-Linux.deb -O yosys.deb \
        &&  sudo -E apt-get install -y --no-install-recommends ./yosys.deb \
        &&  wget https://github.com/Interstellar-Network/abc/releases/download/0.2.0/abc-0.1.1-Linux.deb -O abc.deb \
        &&  sudo apt-get install -y --no-install-recommends ./abc.deb \
	&& sudo apt-get install -y libboost-filesystem-dev libpng-dev libunwind-dev \
    && sudo rm -rf /var/lib/apt/lists/*

###############################################################################
###############################################################################
# end of the "default" image
FROM base AS default

###############################################################################
# Intel SGX Installation
# Extracted and adapted from integritee/integritee-dev:0.2.2 for Ubuntu 22.04
#
# AND from https://github.com/Interstellar-Network/gh-actions/blob/ci-v4/install-sgx-sdk/action.yml 
FROM base AS sgx

# TEMP switch to "root" for simplicity
USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    wget \
    file \
    && rm -rf /var/lib/apt/lists/*

# Define the URLs from your CI script's inputs as ARGs for clarity
ARG SDK_URL=https://download.01.org/intel-sgx/sgx-linux/2.17.1/distro/ubuntu20.04-server/sgx_linux_x64_sdk_2.17.101.1.bin
ARG BIN_URL=https://download.01.org/intel-sgx/sgx-linux/2.17/as.ld.objdump.r4.tar.gz
ARG BINUTILS_DIST=ubuntu20.04

RUN cd /tmp && \
    # Download the SDK installer
    wget -O sdk.bin ${SDK_URL} && \
    chmod +x ./sdk.bin && \
    # Run the installer non-interactively, answering "no" to the license and specifying the install path
    echo -e 'no\n/opt/intel' | ./sdk.bin && \
    rm ./sdk.bin && \
    # Set this variable now for the next steps in this same RUN block
    export SGX_SDK=/opt/intel/sgxsdk && \
    # Download and extract the custom binutils
    wget -O as.ld.objdump.r4.tar.gz ${BIN_URL} && \
    tar xzf as.ld.objdump.r4.tar.gz && \
    # Copy the custom binutils into the SDK directory
    mkdir -p $SGX_SDK/binutils && \
    cp -r external/toolset/${BINUTILS_DIST}/* $SGX_SDK/binutils && \
    # Append the new binutils path to the SDK's environment file
    echo 'export PATH=$SGX_SDK/binutils:$PATH' >> $SGX_SDK/environment && \
    rm -rf ./external ./as.ld.objdump.r4.tar.gz

# These ENV variables make the SDK available to all subsequent commands,
# effectively "sourcing" the environment file for the whole build.
ENV SGX_SDK /opt/intel/sgxsdk
ENV PATH "$SGX_SDK/binutils:$PATH:$SGX_SDK/bin:$SGX_SDK/bin/x64"
ENV PKG_CONFIG_PATH "$PKG_CONFIG_PATH:$SGX_SDK/pkgconfig"
ENV LD_LIBRARY_PATH "$LD_LIBRARY_PATH:$SGX_SDK/sdk_libs"
ENV SGX_MODE SW

# the `ln + find` are needed b/c the .so are versioned eg /usr/lib/x86_64-linux-gnu/libsgx_dcap_ql.so.1.11.110.0
# but the Makefile expects `-lsgx_dcap_ql` to work 
RUN apt-get update && apt-get install -y --no-install-recommends gnupg && \
    mkdir -p /etc/apt/keyrings && \
    wget -O - https://download.01.org/intel-sgx/sgx_repo/ubuntu/intel-sgx-deb.key | tee /etc/apt/keyrings/intel-sgx-keyring.asc > /dev/null && \
    echo 'deb [signed-by=/etc/apt/keyrings/intel-sgx-keyring.asc arch=amd64] https://download.01.org/intel-sgx/sgx_repo/ubuntu jammy main' | tee /etc/apt/sources.list.d/intel-sgx.list && \
    apt-get update && apt-get install -y libsgx-dcap-ql libsgx-dcap-default-qpl && \
    ln -s $(find /usr/lib -type f -name "*sgx_dcap_ql*") /usr/lib/x86_64-linux-gnu/libsgx_dcap_ql.so && \
    ln -s $(find /usr/lib -type f -name "*sgx_dcap_quoteverify*") /usr/lib/x86_64-linux-gnu/libsgx_dcap_quoteverify.so && \
    ln -s $(find /usr/lib -type f -name "*dcap_quoteprov*") /usr/lib/x86_64-linux-gnu/libdcap_quoteprov.so && \
    rm -rf /var/lib/apt/lists/*

# switch back to "myuser"
USER myuser
