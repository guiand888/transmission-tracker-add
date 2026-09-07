# transmission-tracker-add

[![standard-readme compliant](https://img.shields.io/badge/readme%20style-standard-brightgreen.svg?style=flat-square)](https://github.com/RichardLitt/standard-readme)

Applies a public tracker list to every torrent in Transmission, on a schedule, from one small container.

> **This is a fork of [AndrewMarchukov/tracker-add](https://github.com/AndrewMarchukov/tracker-add), which has been abandoned since 2022.**
> Its published image `andrewmhub/transmission-tracker-add` is a frozen 2022 build on Alpine 3.15, end-of-life since 2023-11-01; it logs successes as failures and its tracker-list cache never refreshes, so list updates never arrive. Users diagnosed all of this correctly in the issue tracker and nothing was ever merged.
> Every file in this fork was written from scratch against Transmission's documented JSON-RPC API — it shares only the environment-variable names (`HOSTPORT`, `TORRENTLIST`, `TR_AUTH`) with upstream, so it drops into an existing deployment.

## Table of Contents

- [Install](#install)
- [Usage](#usage)
- [What This Fork Fixes](#what-this-fork-fixes)
- [Maintainers](#maintainers)
- [Acknowledgements](#acknowledgements)
- [Contributing](#contributing)
- [License](#license)

## Install

You need Docker (or Podman) with Compose. Nothing is published to a container registry — Compose builds the image from this repository at a Git tag:

```sh
curl -fsSLO https://raw.githubusercontent.com/guiand888/transmission-tracker-add/main/compose.yaml
curl -fsSL https://raw.githubusercontent.com/guiand888/transmission-tracker-add/main/.env.example -o .env
$EDITOR .env          # set HOSTPORT and TR_AUTH
docker compose up -d
```

To move to a new release, or to pick up an Alpine security patch on the same release:

```sh
TRACKER_ADD_TAG=v1.1.0 docker compose up -d --build     # new version
docker compose build --pull --no-cache && docker compose up -d   # same version, patched base
```

## Usage

`docker compose logs -f tracker-add`

The container reports healthy as long as a pass has *started* within roughly `3 × INTERVAL`; a Transmission outage is logged and retried on its own, and does not make the container unhealthy.

Run once against production without changing anything by setting `DRY_RUN=true`: every read still happens (list fetch, torrent enumeration), and every intended change is logged, but no `torrent-set` call is ever sent — enforced twice, both in the function that would build the request and, as a backstop, in the RPC transport itself. Note that a dry run still writes its own local state (the watermark, the reconcile memo) to `STATE_DIR`, so if you plan to dry-run and then run for real, use a separate `STATE_DIR` or a throwaway container for the dry run.

| Variable | Default | Meaning |
| --- | --- | --- |
| `HOSTPORT` | `localhost:9091` | `host:port` of Transmission's RPC endpoint, as seen from inside this container. |
| `RPC_URL_PATH` | `/transmission/rpc/` | RPC path, if you have moved it. |
| `RPC_TIMEOUT` | `10` | `curl --max-time`, seconds. Keep this below your `stop_grace_period` — a signal during a slow RPC call only returns once the call times out. |
| `RPC_CONNECT_TIMEOUT` | `5` | `curl --connect-timeout`, seconds. |
| `RPC_RETRIES` | `3` | Retries per RPC call before giving up on that call for this pass. |
| `TR_AUTH` | *(empty)* | Transmission RPC credentials as `user:password`. Visible in `/proc/<pid>/environ` and `docker inspect` for the life of the container — prefer `TR_AUTH_FILE` below where you can. |
| `TR_AUTH_FILE` | *(unset)* | Path to a file containing `user:password`. Takes precedence over `TR_AUTH`. |
| `TR_USER_FILE` / `TR_PASS_FILE` | *(unset)* | Paths to files containing the username and password separately (e.g. two Docker secrets). Takes precedence over everything else. |
| `TRACKER_LISTS` | *(unset)* | One or more tracker-list URLs, separated by whitespace or newlines (a YAML block scalar works well here). Merged and deduplicated. |
| `TORRENTLIST` | ngosang `trackers_all.txt` | Deprecated alias for `TRACKER_LISTS`, kept for drop-in compatibility with the upstream image. Still honoured, with a one-time warning at startup. Used only if `TRACKER_LISTS` is unset. |
| `LIST_REFRESH_INTERVAL` | `3600` | Seconds between tracker-list re-fetches. |
| `INTERVAL` | `60` | Seconds between scan passes. |
| `RECONCILE_INTERVAL` | `21600` (6h) | Seconds between reconcile sweeps. |
| `RECONCILE_ON_START` | `true` | Force a reconcile on the container's first pass, so a fresh container backfills coverage instead of only catching new torrents. |
| `RECONCILE_SCOPE` | `active` | `active` reconciles torrents that are queued/downloading/queued-to-seed/seeding; `all` reconciles every public torrent regardless of status. |
| `RECONCILE_CHUNK` | `200` | How many torrents' tracker lists to fetch per RPC call during reconcile. |
| `SKIP_PRIVATE` | `true` | Never add public trackers to a torrent Transmission reports as private. Not configurable to `false` from a "you probably shouldn't" standpoint — it is, deliberately, just an environment variable, not a design ideal. |
| `DRY_RUN` | `false` | Log intended changes; send no mutating RPC call. See above. |
| `LOG_LEVEL` | `INFO` | `ERROR`, `WARN`, `INFO` or `DEBUG`. |
| `STATE_DIR` | `/tmp/ttaa` | Where the tracker-list cache, watermark, reconcile memo and heartbeat live. Must be on writable storage — under `read_only: true` that means a `tmpfs` mount, which is cold on every restart by design. |
| `HEALTH_MAX_AGE` | `3 × INTERVAL + 60` | Seconds since the last heartbeat before the healthcheck reports unhealthy. |
| `TZ` | `UTC` | Timezone for log timestamps. |

`PUID` and `PGID` from the upstream image are gone. The container mounts no volumes, so remapping the runtime UID achieved nothing except forcing a root entrypoint to do the remapping from. It runs as `1001:1001`, fixed at build time.

### Behind a VPN sidecar

To route Transmission and this container through the same VPN container, give this service `network_mode: service:<your-vpn-service>` and set `HOSTPORT=localhost:9091`. In that mode Docker rejects `networks`, `ports`, `hostname`, `dns` and `extra_hosts` on this service — configure them on the VPN service instead. Every hardening option above stays compatible.

## What This Fork Fixes

Transmission does not refresh trackers on torrents you already have. This container talks to Transmission's JSON-RPC API on an interval and adds any tracker from your list that a torrent is missing.

Relative to the abandoned image:

- **The tracker list actually refreshes.** Upstream's cache-freshness check compared a `curl -sI` `Content-Length` header using a case-sensitive match; `raw.githubusercontent.com` serves it lowercase over HTTP/2, so the check always failed and the cache silently froze after its first fetch — for months, in production. This fork uses a conditional `GET` with `ETag`/`If-None-Match` and validates every fetch before using it.
- **Logging is no longer inverted.** Upstream's published `docker` branch had a `grep` with its sense reversed and logged every successful tracker add as a failure (see upstream issue [#28](https://github.com/AndrewMarchukov/tracker-add/issues/28)).
- **No text scraping, no header row.** Upstream parsed `transmission-remote -l`'s human-readable table, and its filter let the header row through as a torrent, spamming "No torrent specified!" once per tracker for a phantom torrent (upstream [#24](https://github.com/AndrewMarchukov/tracker-add/issues/24), [#25](https://github.com/AndrewMarchukov/tracker-add/issues/25)). This fork talks JSON-RPC directly and parses typed fields with `jq`; there is no table and no header row to mistake for data.
- **Nothing is missed regardless of how long a pass takes.** Upstream compared a formatted date string against "now" and "one minute ago" at minute granularity — a slow pass, or one that started a few seconds late, could miss a torrent entirely. This fork tracks an epoch **watermark** from the daemon's own clock, so a slow pass just runs late, never incompletely; a periodic **reconcile** sweep additionally self-heals anything a torrent's trackers are still missing, including torrents added while the container was down.
- **No stale locks.** Upstream's per-torrent lock file was only removed at the end of a successful run, so a killed process left a torrent permanently unprocessed (upstream [#27](https://github.com/AndrewMarchukov/tracker-add/issues/27)). This fork is fully sequential and needs no lock files at all.
- **Private torrents are protected by construction.** Upstream's private-torrent skip (added to its `master` branch, never to the `docker` branch the published image is built from) matched a hand-maintained, empty-by-default hostname allowlist. This fork reads Transmission's own `isPrivate` flag and skips private torrents unconditionally by default — no allowlist to forget to populate.
- **`TORRENTLIST` supports multiple lists,** correctly split on whitespace or newlines (see `TRACKER_LISTS` above), merged and deduplicated.
- **Alpine 3.15 → 3.24**, and `transmission-remote` is gone entirely — the image needs only `bash`, `curl`, `jq`, `ca-certificates` and `tzdata`.
- **Hardened by default:** fixed non-root user `1001:1001`, read-only root filesystem, all Linux capabilities dropped, `no-new-privileges`, a PID limit, and a liveness healthcheck that doesn't depend on Transmission being reachable.
- **Docker only.** Upstream's systemd unit, router script and manual script are gone. There is one supported way to run this.

## Maintainers

[@guiand888](https://github.com/guiand888)

## Acknowledgements

Upstream contributors who diagnosed these exact bugs correctly, in public, and were never merged. Their reports are why this rewrite knew what to fix:

- [@arichiardi](https://github.com/arichiardi) — the header row being parsed as a torrent, and stale lock-file cleanup ([#25](https://github.com/AndrewMarchukov/tracker-add/issues/25), [#27](https://github.com/AndrewMarchukov/tracker-add/issues/27))
- [@cfrost](https://github.com/cfrost) — the inverted `grep` on the `docker` branch that the published image is built from ([#28](https://github.com/AndrewMarchukov/tracker-add/issues/28))
- [@monyxie](https://github.com/monyxie) — the tracker list being fetched once and never refreshed, and the header row
- [@L-ios](https://github.com/L-ios) — non-portable `date` usage
- [@dlenski](https://github.com/dlenski) — fetch-once, and unquoting the tracker-list variable to support more than one URL

## Contributing

Issues and pull requests are welcome. For anything larger than a small fix, please open an issue first to discuss the approach. Bugs in the upstream project are not tracked here — see [Acknowledgements](#acknowledgements) for links to the relevant upstream issues instead.

## License

[AGPL-3.0-or-later](LICENSE) © 2026 Guillaume Andre.
