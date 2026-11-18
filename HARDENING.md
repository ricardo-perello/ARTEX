# Fork hardening

This fork (`ricardo-perello/ARTEX`) pins what upstream (`BaaRai/ARTEX`) fetches at
build time. Run the `hardened` branch. `main` mirrors upstream and is only there to
diff against.

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
| `db/db.go` browser MCP seed | `npx @playwright/mcp` (asks the npm registry on every start) | `playwright-mcp --browser chromium`, the binary installed in the image |
| `Dockerfile` Playwright browsers | Chromium for `playwright` only; the MCP and CLI packages expect another build and cannot launch | both builds installed at image build time |

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
- A database first started on upstream code keeps its `npx` browser MCP row; the
  seed only inserts when the row is absent. Edit it under System → MCP.

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
