# Rust Air-Gapped Development Container

This repository builds a Rust development image for a corporate network that
has no public internet access. The finished container includes Cargo, rustup,
Clippy, rustfmt, rust-analyzer, local Rust documentation, and common native
build tools.

The corporate network must provide two reachable sparse Cargo registries:

- `corp-mirror`: a complete, exact mirror of crates.io;
- `corp-private`: the registry for private corporate crates.

Cargo transparently replaces crates.io dependencies with `corp-mirror` and
uses `corp-private` as the default registry for publishing commands. Git
dependencies are unsupported; publish those dependencies to an internal Cargo
registry before using them in this environment.

## Build workflow

The Dockerfile contains two independent targets. Build `bootstrap` on an
internet-connected machine, transfer that image into the air gap, and build
`corporate` there. The corporate build requires BuildKit so the unrelated
public bootstrap stage is skipped.

### 1. Build and export the bootstrap image

Run this outside the corporate network:

```sh
docker buildx build --load \
  --target bootstrap \
  --build-arg RUST_VERSION=1.97.1 \
  --build-arg DEV_UID=1000 \
  --build-arg DEV_GID=1000 \
  --tag rust-dev-bootstrap:1.97.1-bookworm \
  .

docker save \
  --output rust-dev-bootstrap-1.97.1-bookworm.tar \
  rust-dev-bootstrap:1.97.1-bookworm

sha256sum rust-dev-bootstrap-1.97.1-bookworm.tar \
  > rust-dev-bootstrap-1.97.1-bookworm.tar.sha256
```

Transfer both the tar archive and checksum through the approved import
process.

### 2. Load the bootstrap image inside the air gap

```sh
sha256sum --check rust-dev-bootstrap-1.97.1-bookworm.tar.sha256
docker load --input rust-dev-bootstrap-1.97.1-bookworm.tar
```

The name supplied through `BOOTSTRAP_IMAGE` in the next step must match the
loaded image tag.

### 3. Add corporate CA certificates

Place each corporate root or intermediate CA certificate in `certificates/` as
an individual PEM-encoded file ending in `.crt`. Only public certificates
belong there; never add a private key.

The corporate target installs these files into Debian's system trust store.
The build intentionally fails if the directory contains no `.crt` files.

### 4. Build the corporate image

Run this inside the air-gapped corporate network. Sparse registry URLs must
start with `sparse+https://` and end with `/`.

```sh
docker buildx build --load \
  --target corporate \
  --build-arg BOOTSTRAP_IMAGE=rust-dev-bootstrap:1.97.1-bookworm \
  --build-arg CRATES_IO_MIRROR_INDEX=sparse+https://cargo.example.corp/crates-io/index/ \
  --build-arg PRIVATE_REGISTRY_INDEX=sparse+https://cargo.example.corp/private/index/ \
  --tag rust-dev-corporate:1.97.1 \
  .
```

This step performs no package installation and does not fetch crates. It only
uses the imported bootstrap image, installs the corporate CA certificates, and
records the internal registry endpoints.

## Run the development container

Start an interactive Bash shell and mount the current project directory at
`/workspace`:

```sh
docker run --rm -it \
  --volume "$PWD:/workspace" \
  rust-dev-corporate:1.97.1 \
  bash
```

The container runs as the non-root `developer` user. The `--rm` option removes
the container when the shell exits; files under `/workspace` remain available
because that directory is bind-mounted from the host.

Registry tokens are optional when a registry permits anonymous reads. When
required, set them in the host environment and pass them through at runtime:

```sh
export CARGO_REGISTRIES_CORP_MIRROR_TOKEN='...'
export CARGO_REGISTRIES_CORP_PRIVATE_TOKEN='...'

docker run --rm -it \
  --env CARGO_REGISTRIES_CORP_MIRROR_TOKEN \
  --env CARGO_REGISTRIES_CORP_PRIVATE_TOKEN \
  --volume "$PWD:/workspace" \
  rust-dev-corporate:1.97.1 \
  bash
```

Do not pass tokens as Docker build arguments or store them in the Cargo config.

For a private dependency, use the stable registry name from the image:

```toml
[dependencies]
internal-library = { version = "1.2.3", registry = "corp-private" }
```

Ordinary dependencies need no changes:

```toml
[dependencies]
serde = "1"
```

Cargo resolves the latter through `corp-mirror`, including when an existing
`Cargo.lock` identifies crates.io as the original source.

## Build interface

| Input | Default | Purpose |
| --- | --- | --- |
| `RUST_VERSION` | `1.97.1` | Rust version used by the external bootstrap target |
| `DEV_UID` | `1000` | Numeric UID of the container's `developer` user |
| `DEV_GID` | `1000` | Numeric GID of the container's `developer` group |
| `BOOTSTRAP_IMAGE` | `rust-dev-bootstrap:1.97.1-bookworm` | Imported base used by the corporate target |
| `CRATES_IO_MIRROR_INDEX` | required | Internal crates.io sparse-index URL |
| `PRIVATE_REGISTRY_INDEX` | required | Internal private sparse-index URL |

The UID and GID are fixed when the bootstrap image is built. Set them to the
expected developer IDs when bind-mounted source directories require matching
host ownership.

## Verify the result

Inside the container, these commands should succeed without public network
access:

```sh
rustc --version
cargo --version
cargo clippy --version
rustfmt --version
rust-analyzer --version
rustup component list --installed
cargo fetch --locked
```

Run `cargo fetch --locked` from a project whose complete dependency graph is
present in the internal mirror. A manifest or lockfile containing a `git+`
source will fail because Git dependencies are intentionally unsupported.

## Troubleshoot Docker Desktop with WSL

An error similar to the following occurs before Docker reads this repository's
Dockerfile and indicates a broken Docker Desktop integration with WSL:

```text
/mnt/c/Program Files/Docker/Docker/resources/bin/docker: 13: /usr/bin/docker: Input/output error
```

From Windows PowerShell, not from the WSL shell, shut down WSL:

```powershell
wsl --shutdown
```

Then:

1. Quit Docker Desktop completely and start it again.
2. Open **Settings > Resources > WSL Integration**.
3. Enable integration for the WSL distribution used for this repository.
4. Select **Apply & restart**.

Back in WSL, verify the CLI and BuildKit connection before rebuilding:

```sh
docker version
docker buildx version
```

If the error remains, disable integration for the distribution, apply and
restart, then enable it and apply and restart once more. Calling the Docker
script under `/mnt/c/Program Files/Docker/` does not bypass the problem because
that script redirects WSL back to `/usr/bin/docker`.
