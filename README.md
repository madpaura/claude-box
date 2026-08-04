# claude-box — Claude Code in a minimal container

Run Claude Code inside a container while launching it exactly like you launch
`claude` on the host: `cd` into any folder, run one command, get the TUI in that
folder with your existing login, settings, plugins and skills.

The image is `debian:trixie-slim` + the standalone `claude` native binary (no Node
runtime needed) + `git ripgrep jq less procps curl`. **465 MB**, or 664 MB with the
optional Node.js layer.

## Quickstart

Use a prebuilt image:

```bash
git clone https://github.com/madpaura/claude-box.git
cd claude-box
./pull-image.sh              # ghcr.io/madpaura/claude-box:latest -> claude-code:local

cd ~/some/repo
~/claude-box/claude-box
```

…or build it yourself (recommended if you want to pin versions):

```bash
./build.sh                   # stable release, no Node
./build.sh 2.1.220           # pin a claude version;  ./build.sh latest for newest
./build.sh --node            # include Node.js + npm (current LTS)
```

Make it feel like the real thing from any folder:

```bash
ln -s ~/claude-box/claude-box ~/.local/bin/claude-box
cd ~/some/repo && claude-box
```

### Launcher usage

```
claude-box [-C DIR] [any claude args...]

claude-box                        # run against $PWD
claude-box -C ~/work/repo         # run against another folder
claude-box --continue             # args are passed straight through to claude
claude-box -p "summarise README"  # headless mode works too (no TTY required)
```

Each launch is a fresh `docker run --rm` container — nothing lingers after you exit.

## Prebuilt images (GHCR)

Public, no login required:

| Tag | Contents |
|---|---|
| `ghcr.io/madpaura/claude-box:latest` | newest published base image |
| `ghcr.io/madpaura/claude-box:node` | newest published image with Node.js + npm |
| `ghcr.io/madpaura/claude-box:<claude-version>` | pinned, e.g. `:2.1.220` |
| `ghcr.io/madpaura/claude-box:<claude-version>-node` | pinned, with Node |

```bash
./pull-image.sh              # latest
./pull-image.sh node
./pull-image.sh 2.1.220
```

`pull-image.sh` retags whatever it pulled as `claude-code:local`, which is what
`claude-box` runs by default. `linux/amd64` only — on arm64, build locally with
`./build.sh` (the Dockerfile handles both architectures).

Publishing is manual: run the **Publish images** workflow from the Actions tab (or
push a `v*` tag). It builds both flavours, pushes them to GHCR and smoke-tests them.

## Node.js (optional)

Off by default. Add it when you need `npx`-based MCP servers or JS/TS tooling
inside the container:

```bash
./build.sh --node                          # current LTS
./build.sh --node-version v22.23.2         # pin a version
./build.sh 2.1.220 --node                  # pin both
```

The tarball comes from nodejs.org and is verified against that release's
`SHASUMS256.txt`; it adds ~200 MB. Node builds are tagged
`claude-code:<claude-version>-node`, and archives are named to match. `npm`'s global
prefix is `~/.npm-global` inside the container — which lives in `box-home/` on the
host, so `npm i -g …` works without root and **persists across containers**.

## Ship the image without a registry

```bash
./save-image.sh                              # -> dist/claude-code-<version>.tar.zst
./save-image.sh /media/usb/claude.tar.zst    # or an explicit path

# on the other machine
./load-image.sh dist/claude-code-2.1.220.tar.zst
```

`save-image.sh` uses `zstd` if present, else `pigz`, else `gzip`, and prints the
size and sha256 (138 MB base / 183 MB with Node). `load-image.sh` handles
`.tar.zst` / `.tar.gz` / `.tar` and makes sure `claude-code:local` points at what it
loaded, so `claude-box` works immediately.

## What the container can see

Paths are mounted **at their host locations** so absolute paths in `settings.json`,
session files under `~/.claude/projects/<slug>`, and paths Claude prints all line up
with the host.

| Host | Container | Mode |
|---|---|---|
| `box-home/` | `$HOME` | rw — the container's own `.claude.json` and caches |
| `~/.claude` | `$HOME/.claude` | rw — real login, settings, plugins, skills, sessions |
| `~/.gitconfig` | `$HOME/.gitconfig` | ro |
| the target folder | same path | rw |

Nothing else from `$HOME` is visible. Files created inside come out owned by you: the
launcher runs the container as your uid/gid and hands it a matching `/etc/passwd`
entry, so a prebuilt image works no matter what user it was built for.

`box-home/.claude.json` is seeded on first run with `hasCompletedOnboarding` and a
trust entry for the folder you're opening, so there's no onboarding wizard and no
per-folder trust prompt. It is separate from your host `~/.claude.json` on purpose:
Claude rewrites that file atomically, and a single-file bind mount breaks under an
atomic rename.

## Things worth knowing

- **This isolates the folder, not your account.** The container has your real Claude
  credentials and read/write access to all of `~/.claude` (including other projects'
  sessions). Use it for filesystem/tooling isolation, not as a security boundary
  against the agent itself.
- **No Python, and no Node unless you build with `--node`** (or pull the `:node`
  image). Anything else you need goes on the `apt-get` line in the `Dockerfile`.
- **Git identity is read-only**; `git config --global …` from inside will fail by
  design. No SSH keys are mounted, so pushing happens from the host.
- **Auto-update is off** (`DISABLE_AUTOUPDATER=1`) — `/usr/local/bin/claude` is
  root-owned and the image is immutable. To move versions, `./build.sh <version>` or
  pull a newer tag.
- **The published image contains no credentials** — only Debian packages and the
  Claude Code binary. Your login is mounted in at runtime.

## Switching between images

Both flavours stay tagged after a build, so you can flip without rebuilding:

```bash
docker tag claude-code:2.1.220-node claude-code:local   # use the Node image
docker tag claude-code:2.1.220      claude-code:local   # back to the lean one
```

Or point a single run at either: `CLAUDE_BOX_IMAGE=claude-code:2.1.220-node claude-box`.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | image definition; downloads + SHA256-verifies the claude binary (and Node, if enabled) |
| `build.sh` | builds `claude-code:local` and `claude-code:<version>` with your uid/gid; `--node` opt-in |
| `claude-box` | the launcher — run this in any folder |
| `pull-image.sh` | pull a prebuilt image from GHCR and tag it `claude-code:local` |
| `save-image.sh` | image → compressed archive in `dist/` |
| `load-image.sh` | archive → image, retagged `claude-code:local` |
| `.github/workflows/publish.yml` | manual CI that builds and publishes both flavours to GHCR |
| `box-home/` | container's persistent HOME — `.claude.json`, caches, `.npm-global` (gitignored) |
| `dist/` | saved image archives (gitignored) |

## License

MIT — see [LICENSE](LICENSE).
