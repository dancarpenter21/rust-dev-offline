ARG RUST_VERSION=1.97.1
ARG BOOTSTRAP_IMAGE=rust-dev-bootstrap:1.97.1-bookworm

# Build this target on an internet-connected machine, then export it into the
# air-gapped network. The corporate target below does not depend on this stage,
# so BuildKit will skip it during the air-gapped build.
FROM rust:${RUST_VERSION}-slim-bookworm AS bootstrap

ARG DEV_UID=1000
ARG DEV_GID=1000

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang \
        cmake \
        curl \
        gdb \
        git \
        libclang-dev \
        libssl-dev \
        openssh-client \
        pkg-config; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    rustup component add clippy rust-analyzer rust-docs rustfmt; \
    CARGO_NET_RETRY=10 \
        CARGO_HTTP_TIMEOUT=120 \
        CARGO_HTTP_LOW_SPEED_LIMIT=1 \
        cargo install --locked cargo-watch; \
    rustc --version; \
    cargo --version; \
    cargo clippy --version; \
    cargo watch --version; \
    rustfmt --version; \
    rust-analyzer --version

RUN set -eux; \
    groupadd --gid "${DEV_GID}" developer; \
    useradd \
        --uid "${DEV_UID}" \
        --gid "${DEV_GID}" \
        --create-home \
        --shell /bin/bash \
        developer; \
    mkdir -p /usr/local/cargo/registry /workspace; \
    chown -R developer:developer \
        /usr/local/cargo \
        /usr/local/rustup \
        /workspace

WORKDIR /workspace
USER developer
CMD ["bash"]


# Build this target inside the air-gapped corporate network. BOOTSTRAP_IMAGE
# must name the bootstrap image that was imported with `docker load`.
FROM ${BOOTSTRAP_IMAGE} AS corporate

ARG CRATES_IO_MIRROR_INDEX
ARG PRIVATE_REGISTRY_INDEX

USER root

COPY certificates/*.crt /usr/local/share/ca-certificates/corporate/

RUN set -eux; \
    test -n "${CRATES_IO_MIRROR_INDEX}"; \
    test -n "${PRIVATE_REGISTRY_INDEX}"; \
    case "${CRATES_IO_MIRROR_INDEX}" in \
        sparse+https://*/) ;; \
        *) echo >&2 "CRATES_IO_MIRROR_INDEX must be a sparse+https URL ending in /"; exit 1 ;; \
    esac; \
    case "${PRIVATE_REGISTRY_INDEX}" in \
        sparse+https://*/) ;; \
        *) echo >&2 "PRIVATE_REGISTRY_INDEX must be a sparse+https URL ending in /"; exit 1 ;; \
    esac; \
    update-ca-certificates

COPY config/cargo-config.toml /usr/local/cargo/config.toml
COPY config/cargo-config.toml.template /usr/local/share/rust-dev-offline/cargo-config.toml.template
COPY --chmod=0755 scripts/cargo-fetch-retry /usr/local/bin/cargo-fetch-retry

ENV CARGO_REGISTRIES_CORP_MIRROR_INDEX=${CRATES_IO_MIRROR_INDEX} \
    CARGO_REGISTRIES_CORP_PRIVATE_INDEX=${PRIVATE_REGISTRY_INDEX}

WORKDIR /workspace
USER developer
CMD ["bash"]
