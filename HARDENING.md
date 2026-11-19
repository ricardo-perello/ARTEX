# Fork hardening

This fork (`ricardo-perello/ARTEX`) pins what upstream (`BaaRai/ARTEX`) fetches at
build time. Run the `hardened` branch. The fork's `main` is only the original fork
point and is not kept current; compare against `upstream/main`.

## What differs from upstream

| Where | Upstream | Here |
| --- | --- | --- |
| `Dockerfile` base images, `# syntax` frontend | tag | tag + `@sha256` digest |
| `docker-compose.yml`, `install.sh` Postgres image | tag | tag + digest |
| `Dockerfile` recon tools (nuclei, httpx, subfinder, katana, ffuf, dalfox) | sha256 read from the same release | sha256 written in the Dockerfile |
| `Dockerfile` Node tarball | sha256 read from nodejs.org | sha256 written in the Dockerfile |
| `Dockerfile` bbot | always installed | opt-in: `ARTEX_WITH_BBOT=1` |
| `install.sh` on Linux without Docker | `curl https://get.docker.com \| sh` | stops and asks you to install Docker |
| `npm ci` in `install.sh`, `update.sh`, `build.sh` | runs lifecycle scripts (husky rewrites `core.hooksPath`) | `--ignore-scripts` |
| `skills/api-recon/scripts/package-lock.json` | resolves from `registry.npmmirror.com` | resolves from `registry.npmjs.org` (same integrity hashes) |
| `skills/playwright-cli/SKILL.md` | `@playwright/cli@latest` | `@playwright/cli@0.1.22` |
| `docker-compose.yml` `./skills` mount | read-write | read-only |
| `go.mod` `klauspost/compress` | v1.18.6, in the range of GO-2026-6865 | v1.20.2, the first fixed release |

The browser MCP launch fix this fork carried first (BaaRai/ARTEX#329) is now upstream;
the fork takes upstream's version of `db/db.go` and of the Playwright install step.

GitHub Actions are disabled on the fork.

## Still not pinned

- `apt-get install` packages (only the base image they install onto is pinned).
- Transitive dependencies of the global `npm install -g` Playwright packages. The
  three top-level versions are exact.
- `playwright install --with-deps chromium` (browser build follows the pinned
  Playwright version, the apt dependencies do not).
- Everything bbot installs when `ARTEX_WITH_BBOT=1`.
- Local (non-Docker) mode: Norma runs `npm install -g @vscode/ripgrep`; keep `rg`
  on `PATH` in case that is a fallback for a missing ripgrep. The browser MCP
  server, off by default, needs `playwright-mcp` on `PATH`
  (`npm install -g @playwright/mcp@0.0.83`).

## Running in a VM

For a fresh Ubuntu Server 24.04 guest behind NAT, with no shared folders or
clipboard. Type these in the guest, in this order:

```bash
git clone https://github.com/ricardo-perello/ARTEX.git
cd ARTEX
sudo scripts/vm-egress-firewall.sh
sudo apt-get update
sudo apt-get install -y docker.io docker-buildx docker-compose-v2
sudo ./install.sh
```

Apply the firewall before installing or starting anything else. It rejects traffic
from the guest and from its containers to private, CGNAT (Tailscale), link-local,
multicast and all IPv6 destinations, allows DNS to the guest's gateway only, and
persists across reboots. `sudo scripts/vm-egress-firewall.sh --check` re-runs its
self-test. In `install.sh` choose option 1 (all-Docker).

The UI stays on the guest's `127.0.0.1:8787`. Reach it from a browser inside the
guest, or forward the port deliberately; do not set `ARTEX_BIND_ADDR=0.0.0.0`.

## Known gaps this fork does not close

- **Network reach.** The container is on Docker's default network: the agent's shell
  can try any address the host can route to (host services, LAN, VPN, internet).
  Nothing in the Compose file restricts it to declared targets. Run the stack in a
  disposable VM and apply `scripts/vm-egress-firewall.sh` there (next section). The
  script blocks private, CGNAT and link-local destinations; it does not limit which
  public addresses the agent can reach.
- **Agent and service share one container.** The agent's shell runs beside the
  server and its signing keys, so "needs a login" does not separate the agent from
  the operator. This is why the `klauspost/compress` bump above was taken: skill ZIP
  import and task archive restore both reach the decoder GO-2026-6865 covers.
- **Read-only skills mount, two rough edges.** Deleting a skill in the UI removes
  its database visibility before the file delete fails, and an upload parses the
  archive's manifest before it fails to write.
- **Legacy SSE transport for remote MCP servers.** Unbounded reads, and configured
  headers follow a server-announced URL on another origin. Only add remote MCP
  servers you control.
- **`ask_operator` image path.** Upstream's fix checks the source path, then reopens
  it by name; the destination is also opened by name and the copy has no byte limit.
  A concurrent writer in the task directory could swap the file. Exposure depends on
  what the service can read, in Docker as well as in local mode.
- **Database password redaction.** A connection error can still carry password text
  for DSNs with quoted values or a URL that fails to parse. Do not share startup
  logs from a failed database connection unread.

Source for the last three: a static review of upstream `c2ddd1c` by a second
reviewer. Nothing was reproduced at runtime, and they are not reported upstream.

Go modules are covered by `go.sum` and the Go checksum database, and `web/` by
`package-lock.json` integrity hashes.

## Taking an upstream update

```bash
git fetch upstream
git log --oneline hardened..upstream/main
git diff hardened...upstream/main
git merge upstream/main
```

Read the diff before merging: `Dockerfile`, `go.mod`/`go.sum`, both
`package-lock.json` files, `*.sh`, `.github/`, and anything that adds an outbound
host or a new `exec`. Pushing to `upstream` is disabled in this clone.

## Bumping a pin

- Image digest: `docker buildx imagetools inspect <image>:<tag>` and copy the
  top-level digest.
- Tool or Node version: change the `*_VERSION` and both `*_SHA256_AMD64` /
  `*_SHA256_ARM64` values, taken from that release's checksums file.
