# Minimal Claude Code container image.
#
# Ships the standalone native `claude` binary (no Node runtime needed) on top of
# debian-slim plus the handful of CLI tools Claude actually shells out to.
# The binary is downloaded from Anthropic's release bucket and verified against the
# SHA256 published in that release's manifest.json.

FROM debian:trixie-slim

# CLAUDE_VERSION: stable | latest | X.Y.Z
# WITH_NODE:      1 = also install Node.js + npm (npx-based MCP servers, JS projects)
# NODE_VERSION:   lts | latest | vX.Y.Z
ARG CLAUDE_VERSION=stable
ARG USERNAME=claude
ARG UID=1000
ARG GID=1000
ARG WITH_NODE=0
ARG NODE_VERSION=lts

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git ripgrep jq less procps bash \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    base=https://downloads.claude.ai/claude-code-releases; \
    v="$CLAUDE_VERSION"; \
    case "$v" in stable|latest) v="$(curl -fsSL "$base/$v")";; esac; \
    case "$v" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "bad version: $v" >&2; exit 1;; esac; \
    case "$(dpkg --print-architecture)" in \
      amd64) p=linux-x64;; \
      arm64) p=linux-arm64;; \
      *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1;; \
    esac; \
    sum="$(curl -fsSL "$base/$v/manifest.json" | jq -er ".platforms[\"$p\"].checksum")"; \
    curl -fsSL -o /usr/local/bin/claude "$base/$v/$p/claude"; \
    echo "$sum  /usr/local/bin/claude" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/claude; \
    echo "$v" > /etc/claude-code-version

# Optional: official Node.js tarball (verified against the release SHASUMS256.txt).
# Skipped entirely — no layer cost beyond an echo — when WITH_NODE=0.
RUN set -eux; \
    if [ "$WITH_NODE" = "1" ]; then \
      apt-get update; apt-get install -y --no-install-recommends xz-utils; \
      base=https://nodejs.org/dist; \
      v="$NODE_VERSION"; \
      case "$v" in \
        lts)    v="$(curl -fsSL "$base/index.json" | jq -er '[.[] | select(.lts != false)][0].version')" ;; \
        latest) v="$(curl -fsSL "$base/index.json" | jq -er '.[0].version')" ;; \
      esac; \
      case "$v" in v[0-9]*) ;; *) echo "bad node version: $v" >&2; exit 1;; esac; \
      case "$(dpkg --print-architecture)" in \
        amd64) p=linux-x64;; \
        arm64) p=linux-arm64;; \
        *) echo "unsupported architecture" >&2; exit 1;; \
      esac; \
      tarball="node-$v-$p.tar.xz"; \
      curl -fsSL -o "/tmp/$tarball" "$base/$v/$tarball"; \
      curl -fsSL "$base/$v/SHASUMS256.txt" | grep " $tarball\$" | sed "s#$tarball#/tmp/$tarball#" | sha256sum -c -; \
      tar -xJf "/tmp/$tarball" -C /usr/local --strip-components=1 \
        --exclude CHANGELOG.md --exclude LICENSE --exclude README.md; \
      rm -f "/tmp/$tarball"; \
      apt-get purge -y xz-utils; apt-get autoremove -y; rm -rf /var/lib/apt/lists/*; \
      node --version; npm --version; \
      echo "$v" > /etc/node-version; \
    else \
      echo none > /etc/node-version; \
    fi

RUN set -eux; \
    if ! getent group "$GID" >/dev/null; then groupadd -g "$GID" "$USERNAME"; fi; \
    if ! getent passwd "$UID" >/dev/null; then \
      useradd -u "$UID" -g "$GID" -m -d "/home/$USERNAME" -s /bin/bash "$USERNAME"; \
    fi

# /usr/local/bin is root-owned, so a self-update attempt would only produce noise.
# npm's global prefix points into HOME (i.e. into the mounted box-home), so
# `npm i -g` works without root and survives across ephemeral containers.
# These are defaults for a bare `docker run`; claude-box overrides HOME, PATH and
# NPM_CONFIG_PREFIX at runtime so a prebuilt image works for any user/home path.
ENV DISABLE_AUTOUPDATER=1 \
    LANG=C.UTF-8 \
    HOME=/home/$USERNAME \
    NPM_CONFIG_PREFIX=/home/$USERNAME/.npm-global \
    PATH=/home/$USERNAME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin

USER $UID:$GID
WORKDIR /home/$USERNAME
ENTRYPOINT ["/usr/local/bin/claude"]
