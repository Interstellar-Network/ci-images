################################################################################
#
# We use this b/c we want two versions of this Dockerfile:
# - one used for lib_circuits/lib_garble CI: directly based on eg Ubuntu
# - one used for api_circuits/api_garble CI and/or prod container: based instead on eg rust:XX
# NOTE: we do it this way b/c the Rust projects depend on the CPP one, and for now at least, they recompile
# the C++ from source.
ARG BASE_IMAGE=ubuntu:24.04

FROM $BASE_IMAGE as builder

# SSH KEY of a user with access to all the Org's repos
ARG SSH_KEY

# DEBIAN_FRONTEND needed to stop prompt for timezone
ENV DEBIAN_FRONTEND=noninteractive

# Store SSH KEY
RUN test -n "$SSH_KEY" || (echo "SSH_KEY not set" && false)
RUN mkdir -p ~/.ssh \
    && echo "$SSH_KEY" >> ~/.ssh/id_ed25519 \
    && chmod 600 ~/.ssh/id_ed25519 

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

# RUST specifics
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y ;\
    cat $HOME/.cargo/env 

# https://doc.rust-lang.org/cargo/reference/config.html#netgit-fetch-with-cli
# Needed to use private GitHub repo as `Cargo` git dependencies
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true

# equivalent to `. "$HOME/.cargo/env"`
ENV PATH="/root/.cargo/bin:${PATH}"

# Add GitHub to known hosts to avoid a prompt
RUN ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null

# Install mold(linker)
# Set it as default(ie replace ld) b/c Rust tends to NOT correctly detect
# RUSTFLAGS and that force things to recompile from scratch
#
# https://github.com/rui314/setup-mold/blob/main/action.yml
# version=$(wget -q -O- https://api.github.com/repos/rui314/mold/releases/latest | jq -r .tag_name | sed 's/^v//'); true
RUN export version=2.37.1 && \
    wget -O- https://github.com/rui314/mold/releases/download/v$version/mold-$version-$(uname -m)-linux.tar.gz | tar -C /usr/local --strip-components=1 -xzf - && \
    sudo chmod +x /usr/local/bin/mold && \
    ln -sf /usr/local/bin/mold $(realpath /usr/bin/ld)

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
RUN apt-get update && \
	wget https://github.com/Interstellar-Network/yosys/releases/download/yosys-0.29/yosys-0.1.29-Linux.deb -O yosys.deb \
        &&  sudo apt-get install -y --no-install-recommends ./yosys.deb \
        &&  wget https://github.com/Interstellar-Network/abc/releases/download/0.2.0/abc-0.1.1-Linux.deb -O abc.deb \
        &&  sudo apt-get install -y --no-install-recommends ./abc.deb \
	&& sudo apt-get install -y libboost-filesystem-dev libpng-dev libunwind-dev \
    && rm -rf /var/lib/apt/lists/*

# TESTING: uncomment
# RUN git clone --recursive git@github.com:Interstellar-Network/lib_circuits-internal.git repo

# Add the current sources
# NOTE this works in tandem with `.dockerignore`
COPY . ./repo/

CMD cd repo && cargo test
