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
claude-box [-C DIR] [--inhouse] [any claude args...]

claude-box                        # run against $PWD
claude-box -C ~/work/repo         # run against another folder
claude-box --inhouse              # use the in-house LLM gateway (see below)
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

## Using an in-house OpenAI-compatible LLM gateway

Claude Code only speaks the **Anthropic Messages API**. If your organisation runs an
OpenAI-compatible gateway (`/chat/completions`), it needs a translating proxy in
front. `llm-gateway/` ships one: a pinned LiteLLM sidecar that exposes
`/v1/messages`, forwards to your gateway's `/chat/completions`, and injects the
identifying headers the gateway expects.

```
claude-box  ──/v1/messages──▶  LiteLLM sidecar  ──/chat/completions──▶  in-house gateway
                               (adds RooCode headers + bearer token)
```

**1. Check what your gateway supports** — run this from a machine that can reach it:

```bash
./llm-gateway/probe.py --base-url http://gateway.internal/v1 \
                       --token "$INHOUSE_LLM_TOKEN" --model admin
```

It reports whether the gateway already speaks the Anthropic API (in which case skip
the sidecar entirely), whether `/chat/completions` works, and — the make-or-break
test — whether the model returns `tool_calls`. **Claude Code cannot function without
OpenAI function calling**: every file read, edit and command is a tool call.

**2. Configure and start the sidecar:**

```bash
cp llm-gateway/gateway.env.example llm-gateway/gateway.env
chmod 600 llm-gateway/gateway.env     # base URL, token, model names
$EDITOR llm-gateway/gateway.env

./llm-gateway/gateway.sh up           # start   (status | logs | down | restart)
```

**3. Run Claude Code against it:**

```bash
cd ~/some/repo
claude-box --inhouse
```

`--inhouse` joins the container to the sidecar's docker network and sets
`ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` plus all model slots
(`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL`), so whichever model your
`settings.json` selects resolves to the gateway. It also sets
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `DISABLE_TELEMETRY=1`. Without the
flag, nothing changes — you still talk to Anthropic with your normal login.

**Model names are your gateway's real names.** The proxy registers each model twice —
under the gateway's own name (e.g. `DSllmOCoderStable`) and under a stable alias
(`inhouse-main` / `inhouse-small`) — and Claude Code is pointed at the real name. That
way the name Claude Code sends is a name your gateway accepts even if something in the
chain forwards the requested name instead of the mapped one. `gateway.sh status` lists
every name you can pass to `/model`.

### Gateway files

| File | Purpose |
|---|---|
| `llm-gateway/gateway.env.example` | template for base URL, token, model names (copy to `gateway.env`, gitignored) |
| `llm-gateway/config.yaml` | LiteLLM config: model mapping, custom headers, param dropping |
| `llm-gateway/gateway.sh` | `up` / `down` / `status` / `logs` / `restart` for the sidecar |
| `llm-gateway/probe.py` | connectivity + capability probe (stdlib only, run it anywhere) |
| `llm-gateway/mock-openai.py` | fake gateway for testing the pipeline offline |

### Notes and limits

- **Two config lines matter more than the rest.** `drop_params: true` discards the
  Anthropic-only fields Claude Code sends (`cache_control`, thinking blocks, betas).
  `use_chat_completions_url_for_anthropic_messages: true` is essential: without it
  LiteLLM serves `/v1/messages` by calling the upstream *Responses API*
  (`/v1/responses`), which in-house gateways generally don't implement — every
  request 404s.
- **No prompt caching** through the bridge, so long sessions re-send context and cost
  more latency than they would against Anthropic.
- **Custom headers** are set per model in `config.yaml` under `extra_headers` — the
  RooCode `User-Agent` / `X-Title` / `HTTP-Referer` trio. Change them there if your
  gateway was provisioned against a different client.
- **Context window**: if the gateway's model has a smaller window than Claude's,
  set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` in the launcher env to avoid overflow errors.
- **Testing without the gateway**: run `./llm-gateway/mock-openai.py` and point
  `gateway.env` at `http://host.docker.internal:8899/v1` — it logs the headers it
  receives, so you can confirm what actually reaches the upstream.

### Troubleshooting

**`API Error: 402 {"detail":"The <model> you used is not available…"}`** — that reply
comes from your gateway, not Anthropic, so the plumbing is working; the gateway just
doesn't recognise the model name it received. Check `gateway.sh status` lists the name
you selected with `/model`, and prefer the gateway's real model names over the
aliases.

**See exactly what the proxy sends upstream:**

```bash
./llm-gateway/gateway.sh up --debug
# reproduce the failure, then:
./llm-gateway/gateway.sh logs 2>&1 | grep -A3 "POST Request Sent"
```

That prints the literal upstream request — model name, headers and body — which
settles whether the problem is on the Claude Code side, the proxy mapping, or the
gateway.

**Check the proxy in isolation**, without Claude Code in the picture:

```bash
curl -sS http://127.0.0.1:4000/v1/messages \
  -H "x-api-key: $LITELLM_MASTER_KEY" -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' \
  -d '{"model":"<your model>","max_tokens":32,"messages":[{"role":"user","content":"hi"}]}'
```

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
