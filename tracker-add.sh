#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# tracker-add.sh — apply a public tracker list to every torrent in
# Transmission, over its JSON-RPC API.
#
# Part of transmission-tracker-add
# (https://github.com/guiand888/transmission-tracker-add), a from-scratch
# rewrite of the abandoned AndrewMarchukov/tracker-add. See the README for
# the "why" and the full fixes list.
#
# Design invariants — do not relax without reading the linked source first:
#
#   - torrent-set is ALWAYS called with exactly one torrent id. Transmission
#     4.0.6's rpcimpl.cc:1172/1280 declares its per-request error state
#     OUTSIDE the per-torrent loop and guards every later torrent on it
#     being null, so a duplicate-tracker error on the FIRST id in a batch
#     silently skips every id after it. Batching ids is a correctness bug,
#     not a missed optimization.
#
#   - Only http/https/udp tracker URLs are ever sent to the daemon.
#     Transmission 4.0.6's web-utils.cc:226 accepts only those three
#     schemes; anything else (e.g. ws:// / wss://) is rejected before the
#     daemon's own dedup logic runs, so trackerCount() never changes and
#     the daemon reports the same benign "error setting announce list" as
#     a real duplicate. Treating that error as benign is only safe BECAUSE
#     we pre-filter to the three accepted schemes — the two facts are
#     coupled.
#
#   - Every RPC call goes through rpc_call(), which owns the
#     X-Transmission-Session-Id 409 handshake. The session id can rotate at
#     any time, so the handshake wraps every call, not just the first.
#
#   - Fully sequential. The only backgrounded job anywhere in this script is
#     the `sleep` inside interruptible_sleep(), which is always `wait`ed on
#     before the function returns. There is no other concurrency, so there
#     are no lock files — the old project's /tmp/TTAA.*.lock mechanism
#     existed to guard against overlapping invocations, a failure mode a
#     single sequential loop does not have. Do not add it back.
#
#   - Never `local x=$(cmd)`. Combining `local` with a command substitution
#     on one line masks the substitution's exit status (the exit status of
#     `local` itself is returned instead), which silently defeats
#     `set -e`. Always declare, then assign on a separate statement.
#
# Environment variables (defaults applied in load_config):
#   HOSTPORT               localhost:9091   host:port of the Transmission RPC endpoint
#   RPC_URL_PATH            /transmission/rpc/
#   RPC_TIMEOUT             10               curl --max-time, seconds. Keep below
#                                             the compose stop_grace_period.
#   RPC_CONNECT_TIMEOUT     5
#   RPC_RETRIES             3
#   TR_AUTH                                  "user:pass". See README for the
#                                             /proc/<pid>/environ caveat.
#   TR_AUTH_FILE                             path to a file containing "user:pass"
#   TR_USER_FILE / TR_PASS_FILE              paths to files containing user / pass
#                                             separately (highest precedence)
#   TRACKER_LISTS                            whitespace/newline separated tracker
#                                             list URLs
#   TORRENTLIST                              deprecated alias for a single URL,
#                                             still honoured with a warning
#   LIST_REFRESH_INTERVAL   3600             seconds between tracker-list re-fetches
#   INTERVAL                60               seconds between scan passes
#   RECONCILE_INTERVAL      21600            seconds between reconcile sweeps (6h)
#   RECONCILE_ON_START      true             force a reconcile on the first pass
#   RECONCILE_SCOPE         active           "active" (status 3-6) or "all"
#   RECONCILE_CHUNK         200              torrent-get paging size for reconcile
#   SKIP_PRIVATE            true             never add public trackers to private torrents
#   DRY_RUN                 false            log intended changes, send no mutating RPC
#   LOG_LEVEL               INFO             ERROR, WARN, INFO or DEBUG
#   STATE_DIR               /tmp/ttaa        all local state; must be writable (tmpfs)
#   HEALTH_MAX_AGE          INTERVAL*3+60    healthcheck staleness window, seconds
#   TZ                                       timezone for log timestamps

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly PROGRAM_NAME="tracker-add"
readonly DEFAULT_TRACKER_LIST="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"

# What we SEND to the daemon. Transmission 4.0.6 (web-utils.cc:226) accepts
# only these three schemes; anything else is silently dropped server-side.
readonly SEND_SCHEME_RE='^(https?|udp)://'

# What we accept when VALIDATING a freshly fetched list file (its job is
# rejecting an HTML error page, not enforcing what the daemon will accept —
# ws/wss entries are allowed to sit in the cache, they are just filtered out
# by SEND_SCHEME_RE before anything is ever sent).
readonly VALIDATE_SCHEME_RE='^(https?|udp|wss?)://'

readonly MUTATING_METHODS_RE='^(torrent-set|torrent-add|torrent-remove|torrent-set-location|session-set)$'

# ---------------------------------------------------------------------------
# Logging — leveled, no coreutils dependency.
# ---------------------------------------------------------------------------

declare -A LOG_LEVELS=([ERROR]=0 [WARN]=1 [INFO]=2 [DEBUG]=3)

log() {
  local level=$1; shift
  local threshold=${LOG_LEVELS[${LOG_LEVEL:-INFO}]:-2}
  local this=${LOG_LEVELS[$level]:-2}
  (( this <= threshold )) || return 0
  local ts
  printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
    printf '%s [%s] %s\n' "$ts" "$level" "$*" >&2
  else
    printf '%s [%s] %s\n' "$ts" "$level" "$*"
  fi
}
log_error() { log ERROR "$@"; }
log_warn()  { log WARN  "$@"; }
log_info()  { log INFO  "$@"; }
log_debug() { log DEBUG "$@"; }

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

load_config() {
  HOSTPORT=${HOSTPORT:-localhost:9091}
  RPC_URL_PATH=${RPC_URL_PATH:-/transmission/rpc/}
  RPC_TIMEOUT=${RPC_TIMEOUT:-10}
  RPC_CONNECT_TIMEOUT=${RPC_CONNECT_TIMEOUT:-5}
  RPC_RETRIES=${RPC_RETRIES:-3}

  LIST_REFRESH_INTERVAL=${LIST_REFRESH_INTERVAL:-3600}
  INTERVAL=${INTERVAL:-60}
  RECONCILE_INTERVAL=${RECONCILE_INTERVAL:-21600}
  RECONCILE_ON_START=${RECONCILE_ON_START:-true}
  RECONCILE_SCOPE=${RECONCILE_SCOPE:-active}
  RECONCILE_CHUNK=${RECONCILE_CHUNK:-200}

  SKIP_PRIVATE=${SKIP_PRIVATE:-true}
  DRY_RUN=${DRY_RUN:-false}
  LOG_LEVEL=${LOG_LEVEL:-INFO}
  STATE_DIR=${STATE_DIR:-/tmp/ttaa}
  HEALTH_MAX_AGE=${HEALTH_MAX_AGE:-$(( INTERVAL * 3 + 60 ))}

  local name
  for name in RPC_TIMEOUT RPC_CONNECT_TIMEOUT RPC_RETRIES LIST_REFRESH_INTERVAL \
              INTERVAL RECONCILE_INTERVAL RECONCILE_CHUNK HEALTH_MAX_AGE; do
    [[ "${!name}" =~ ^[0-9]+$ ]] || { log_error "config: $name must be a positive integer, got '${!name}'"; exit 1; }
  done
  [[ "${LOG_LEVELS[$LOG_LEVEL]+x}" ]] || { log_error "config: LOG_LEVEL must be one of ERROR WARN INFO DEBUG, got '$LOG_LEVEL'"; exit 1; }
  case "$RECONCILE_SCOPE" in
    active|all) ;;
    *) log_error "config: RECONCILE_SCOPE must be 'active' or 'all', got '$RECONCILE_SCOPE'"; exit 1 ;;
  esac
  case "$DRY_RUN" in
    true|false) ;;
    *) log_error "config: DRY_RUN must be 'true' or 'false', got '$DRY_RUN'"; exit 1 ;;
  esac
  case "$SKIP_PRIVATE" in
    true|false) ;;
    *) log_error "config: SKIP_PRIVATE must be 'true' or 'false', got '$SKIP_PRIVATE'"; exit 1 ;;
  esac
  case "$RECONCILE_ON_START" in
    true|false) ;;
    *) log_error "config: RECONCILE_ON_START must be 'true' or 'false', got '$RECONCILE_ON_START'"; exit 1 ;;
  esac
}

resolve_list_urls() {
  local raw=""
  if [[ -n "${TRACKER_LISTS:-}" ]]; then
    raw="$TRACKER_LISTS"
  elif [[ -n "${TORRENTLIST:-}" ]]; then
    raw="$TORRENTLIST"
  else
    raw="$DEFAULT_TRACKER_LIST"
  fi

  LIST_URLS=()
  local u
  # Intentional word-splitting: raw is a whitespace/newline separated list
  # of URLs, not a single token.
  # shellcheck disable=SC2086
  for u in $raw; do
    [[ -n "$u" ]] && LIST_URLS+=("$u")
  done
}

load_credentials() {
  CREDS=""
  CRED_SOURCE="none"

  if [[ -n "${TR_USER_FILE:-}" && -n "${TR_PASS_FILE:-}" ]]; then
    [[ -r "$TR_USER_FILE" ]] || { log_error "TR_USER_FILE set but not readable: $TR_USER_FILE"; exit 1; }
    [[ -r "$TR_PASS_FILE" ]] || { log_error "TR_PASS_FILE set but not readable: $TR_PASS_FILE"; exit 1; }
    local user pass
    IFS= read -r user < "$TR_USER_FILE"
    IFS= read -r pass < "$TR_PASS_FILE"
    CREDS="${user}:${pass}"
    CRED_SOURCE="TR_USER_FILE/TR_PASS_FILE"
  elif [[ -n "${TR_AUTH_FILE:-}" ]]; then
    [[ -r "$TR_AUTH_FILE" ]] || { log_error "TR_AUTH_FILE set but not readable: $TR_AUTH_FILE"; exit 1; }
    IFS= read -r CREDS < "$TR_AUTH_FILE"
    CRED_SOURCE="TR_AUTH_FILE"
  elif [[ -n "${TR_AUTH:-}" ]]; then
    CREDS="$TR_AUTH"
    CRED_SOURCE="TR_AUTH (visible in /proc/<pid>/environ — prefer TR_AUTH_FILE)"
  fi

  build_curl_cfg
}

# curl config-file form for credentials: never on argv (would leak into
# `ps`/cmdline), never written to disk (unlike --netrc-file). Fed to curl
# via `printf ... | curl --config -`.
build_curl_cfg() {
  CURL_CFG=""
  [[ -n "$CREDS" ]] || return 0
  local esc=${CREDS//\\/\\\\}
  esc=${esc//\"/\\\"}
  CURL_CFG="user = \"$esc\""
}

banner() {
  log_info "$PROGRAM_NAME starting"
  log_info "  endpoint: http://${HOSTPORT}${RPC_URL_PATH}"
  log_info "  credentials: $CRED_SOURCE"
  log_info "  scan interval: ${INTERVAL}s / reconcile interval: ${RECONCILE_INTERVAL}s (scope=$RECONCILE_SCOPE, chunk=$RECONCILE_CHUNK)"
  log_info "  skip private torrents: $SKIP_PRIVATE / dry run: $DRY_RUN / log level: $LOG_LEVEL"
  log_info "  state dir: $STATE_DIR / tz: ${TZ:-UTC}"
  log_info "  tracker list source(s): ${LIST_URLS[*]}"
  if [[ -n "${TORRENTLIST:-}" && -z "${TRACKER_LISTS:-}" ]]; then
    log_warn "TORRENTLIST is deprecated; set TRACKER_LISTS instead (TORRENTLIST is still honoured this run)"
  fi
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

SESSION_ID=""
HTTP_CODE=""

http_post_once() {
  local method=$1 args_json=$2
  local req_file="$STATE_DIR/req.json" body_file="$STATE_DIR/resp.json" hdr_file="$STATE_DIR/resp.hdr"

  jq -cn --arg m "$method" --argjson a "$args_json" '{method:$m, arguments:$a, tag:1}' > "$req_file"

  local -a hdr_args=()
  [[ -n "$SESSION_ID" ]] && hdr_args=(-H "X-Transmission-Session-Id: $SESSION_ID")

  local rc=0
  HTTP_CODE=$(printf '%s\n' "$CURL_CFG" | curl -sS --config - \
      --connect-timeout "$RPC_CONNECT_TIMEOUT" --max-time "$RPC_TIMEOUT" \
      -X POST -H 'Content-Type: application/json' \
      "${hdr_args[@]}" \
      --data-binary @"$req_file" \
      -D "$hdr_file" -o "$body_file" -w '%{http_code}' \
      "http://${HOSTPORT}${RPC_URL_PATH}") || rc=$?
  return $rc
}

# rpc_call METHOD ARGS_JSON
# Return codes:
#   0  success                          2  HTTP != 200 after retries
#   3  broken 409 handshake             4  auth rejected (fatal — caller should exit)
#   5  RPC-level error                  10 benign no-change (duplicate / rejected scheme)
#   90 DRY_RUN safety-net violation (should be unreachable)
rpc_call() {
  local method=$1 args_json=$2 attempt=0 rc

  if [[ "$DRY_RUN" == true && "$method" =~ $MUTATING_METHODS_RE ]]; then
    log_error "BUG: mutating method '$method' reached the transport under DRY_RUN"
    return 90
  fi

  while (( attempt < RPC_RETRIES )); do
    (( attempt++ )) || true
    rc=0
    http_post_once "$method" "$args_json" || rc=$?

    if (( rc != 0 )); then
      log_warn "rpc transport error (curl exit $rc), attempt $attempt/$RPC_RETRIES for $method"
      interruptible_sleep $(( 2 ** attempt ))
      continue
    fi

    case "$HTTP_CODE" in
      409)
        local sid
        sid=$(grep -i '^x-transmission-session-id:' "$STATE_DIR/resp.hdr" | tr -d '\r' | sed 's/^[^:]*: *//' | tail -n1) || true
        if [[ -z "$sid" ]]; then
          log_error "409 response carried no session id header"
          return 3
        fi
        SESSION_ID="$sid"
        log_debug "session id refreshed"
        continue
        ;;
      401|403)
        log_error "RPC auth rejected (HTTP $HTTP_CODE) — check TR_AUTH/TR_AUTH_FILE"
        return 4
        ;;
      200)
        break
        ;;
      *)
        log_warn "unexpected HTTP $HTTP_CODE from RPC, attempt $attempt/$RPC_RETRIES for $method"
        interruptible_sleep $(( 2 ** attempt ))
        continue
        ;;
    esac
  done

  [[ "$HTTP_CODE" == 200 ]] || return 2

  local result
  result=$(jq -r '.result // "missing"' "$STATE_DIR/resp.json")
  case "$result" in
    success)
      return 0
      ;;
    "error setting announce list")
      # Benign: the daemon's tracker count did not change. Either every
      # tracker we sent was already present, or one we sent used a scheme
      # the daemon rejects. The second case is why SEND_SCHEME_RE exists —
      # see the header comment.
      return 10
      ;;
    *)
      log_error "RPC error for $method: $result"
      return 5
      ;;
  esac
}

wait_for_daemon() {
  local attempts=0 rc
  while true; do
    rc=0
    rpc_call session-get '{"fields":["rpc-version","rpc-version-minimum","version"]}' || rc=$?
    case $rc in
      0) return 0 ;;
      4) log_error "auth rejected while waiting for the daemon — exiting"; exit 1 ;;
      *)
        (( attempts++ )) || true
        if (( attempts % 6 == 0 )); then
          log_warn "still waiting for Transmission RPC at http://${HOSTPORT}${RPC_URL_PATH} (attempt $attempts)"
        fi
        interruptible_sleep 5
        ;;
    esac
  done
}

assert_rpc_version() {
  local rpc_version daemon_version
  rpc_version=$(jq -r '.arguments["rpc-version"] // 0' "$STATE_DIR/resp.json")
  daemon_version=$(jq -r '.arguments.version // "unknown"' "$STATE_DIR/resp.json")
  log_info "connected to Transmission $daemon_version, RPC version $rpc_version"

  if (( rpc_version >= 18 )); then
    log_error "RPC version $rpc_version (>= 18, JSON-RPC 2.0 / snake_case) is not supported by this script — refusing to run"
    exit 1
  fi

  if (( rpc_version < 17 )); then
    log_warn "RPC version $rpc_version < 17: trackerList is unavailable, reconcile will read trackers[].announce instead"
    HAVE_TRACKER_LIST=false
  else
    HAVE_TRACKER_LIST=true
  fi
}

# ---------------------------------------------------------------------------
# Tracker lists
# ---------------------------------------------------------------------------

list_cache_key() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

validate_list_file() {
  local f=$1
  [[ -s "$f" ]] || return 1
  local first_line=""
  IFS= read -r first_line < "$f" || true
  [[ "$first_line" != "<"* ]] || return 1
  grep -qE "$VALIDATE_SCHEME_RE" "$f" || return 1
  return 0
}

fetch_one_list() {
  local url=$1 key tmp hdr etag=""
  key=$(list_cache_key "$url")
  tmp="$STATE_DIR/lists/$key.tmp"
  hdr="$STATE_DIR/lists/$key.hdr"
  if [[ -r "$STATE_DIR/lists/$key.etag" ]]; then
    IFS= read -r etag < "$STATE_DIR/lists/$key.etag" || true
  fi

  local -a etag_args=()
  [[ -n "$etag" ]] && etag_args=(-H "If-None-Match: $etag")

  local code rc=0
  code=$(curl -sS --connect-timeout 5 --max-time 30 -L \
      "${etag_args[@]}" \
      -o "$tmp" -D "$hdr" -w '%{http_code}' "$url") || rc=$?

  if (( rc != 0 )); then
    log_warn "list fetch failed ($url, curl exit $rc); keeping cached copy if any"
    return 1
  fi
  if [[ "$code" == "304" ]]; then
    log_debug "list unchanged (304): $url"
    return 0
  fi
  if [[ "$code" != "200" ]]; then
    log_warn "list fetch returned HTTP $code ($url); keeping cached copy if any"
    return 1
  fi
  if ! validate_list_file "$tmp"; then
    log_warn "list failed validation ($url); keeping cached copy if any"
    return 1
  fi

  local new_etag
  new_etag=$(grep -i '^etag:' "$hdr" | tr -d '\r' | sed 's/^[^:]*: *//' | tail -n1) || true
  if [[ -n "$new_etag" ]]; then
    printf '%s\n' "$new_etag" > "$STATE_DIR/lists/$key.etag"
  fi
  mv -f "$tmp" "$STATE_DIR/lists/$key.txt"
  log_debug "list refreshed: $url"
  return 0
}

refresh_lists() {
  mkdir -p "$STATE_DIR/lists"
  local url
  for url in "${LIST_URLS[@]}"; do
    fetch_one_list "$url" || true
  done

  local merged="$STATE_DIR/merged.txt.tmp"
  : > "$merged"
  local f
  for f in "$STATE_DIR"/lists/*.txt; do
    [[ -e "$f" ]] || continue
    cat "$f" >> "$merged"
  done

  grep -E "$SEND_SCHEME_RE" "$merged" | sort -u > "$STATE_DIR/merged.txt.sorted" || true
  mv -f "$STATE_DIR/merged.txt.sorted" "$STATE_DIR/merged.txt"
  rm -f "$merged"

  if [[ ! -s "$STATE_DIR/merged.txt" ]]; then
    log_warn "merged tracker list is empty after refresh — no valid cached list is available"
    return 1
  fi

  local sha old_sha=""
  sha=$(sha256sum "$STATE_DIR/merged.txt" | cut -d' ' -f1)
  [[ -r "$STATE_DIR/merged.sha" ]] && { IFS= read -r old_sha < "$STATE_DIR/merged.sha" || true; }
  if [[ "$sha" != "$old_sha" ]]; then
    printf '%s\n' "$sha" > "$STATE_DIR/merged.sha"
    local n
    n=$(wc -l < "$STATE_DIR/merged.txt")
    log_info "tracker list changed: $n entries, sha=${sha:0:12}"
  fi
  return 0
}

maybe_refresh_lists() {
  local now=$EPOCHSECONDS last=0
  [[ -r "$STATE_DIR/lists_refreshed_at" ]] && { IFS= read -r last < "$STATE_DIR/lists_refreshed_at" || true; }
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last >= LIST_REFRESH_INTERVAL )) || [[ ! -s "$STATE_DIR/merged.txt" ]]; then
    if refresh_lists; then
      printf '%s\n' "$now" > "$STATE_DIR/lists_refreshed_at"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Core: snapshot, watermark scan, reconcile
# ---------------------------------------------------------------------------

declare -A PROCESSED_AT_WATERMARK=()

# Fetches the fields both scan_new() and reconcile()'s listing phase need,
# ONCE per loop iteration, into $STATE_DIR/snapshot.json. Both then read
# that file instead of each issuing their own torrent-get.
refresh_snapshot() {
  local rc=0
  rpc_call torrent-get '{"fields":["hashString","name","addedDate","isPrivate","status"]}' || rc=$?
  if (( rc != 0 )); then
    log_warn "torrent-get (snapshot) failed (rc=$rc)"
    return 1
  fi
  cp -f "$STATE_DIR/resp.json" "$STATE_DIR/snapshot.json"
  return 0
}

read_watermark() {
  WATERMARK=0
  [[ -r "$STATE_DIR/watermark" ]] && { IFS= read -r WATERMARK < "$STATE_DIR/watermark" || true; }
  [[ "$WATERMARK" =~ ^[0-9]+$ ]] || WATERMARK=0
}

write_watermark() {
  printf '%s\n' "$WATERMARK" > "$STATE_DIR/watermark"
}

# apply_trackers HASH NAME — sends the full merged list as trackerAdd for
# one torrent. Additive only (never trackerList/replace) so a bug here can
# never delete a torrent's existing trackers.
apply_trackers() {
  local hash=$1 name=$2

  if [[ "$DRY_RUN" == true ]]; then
    local count
    count=$(wc -l < "$STATE_DIR/merged.txt")
    log_info "[DRY_RUN] would add up to $count tracker(s) to \"$name\" ($hash)"
    return 0
  fi

  local args
  args=$(jq -cn --arg h "$hash" --rawfile l "$STATE_DIR/merged.txt" \
      '{ids:[$h], trackerAdd:($l | split("\n") | map(select(length>0)))}')

  local rc=0
  rpc_call torrent-set "$args" || rc=$?
  case $rc in
    0)  log_info "\"$name\" ($hash): trackers applied" ;;
    10) log_debug "\"$name\" ($hash): no change (already present or rejected scheme)" ;;
    *)  log_warn "\"$name\" ($hash): apply_trackers failed (rc=$rc)" ;;
  esac
  return 0
}

process_torrent() {
  local hash=$1 name=$2 is_private=$3

  if [[ "$SKIP_PRIVATE" == true && "$is_private" == true ]]; then
    log_info "\"$name\" ($hash): skipped (private torrent)"
    return 0
  fi
  apply_trackers "$hash" "$name"
}

# scan_new — watermark pass. Reads $STATE_DIR/snapshot.json (populated by
# refresh_snapshot in the same loop iteration). Watermark is max(addedDate)
# from DAEMON data, never the local clock, so container/daemon clock skew
# cannot cause a missed torrent. Comparison is inclusive (>=): over-included
# torrents are idempotent no-ops; under-inclusion would be a real miss.
scan_new() {
  local body="$STATE_DIR/snapshot.json"
  [[ -s "$body" ]] || return 0

  local max_seen=$WATERMARK
  local hash added private name

  while IFS=$'\t' read -r hash added private name; do
    [[ -n "$hash" ]] || continue
    if (( added > max_seen )); then
      max_seen=$added
    fi
    if (( added < WATERMARK )); then
      continue
    fi
    if (( added == WATERMARK )) && [[ -n "${PROCESSED_AT_WATERMARK[$hash]:-}" ]]; then
      continue
    fi
    process_torrent "$hash" "$name" "$private"
    if (( added == WATERMARK )); then
      PROCESSED_AT_WATERMARK[$hash]=1
    fi
  done < <(jq -r '.arguments.torrents[] | select(.addedDate != null) |
      [.hashString, .addedDate, (.isPrivate|tostring), .name] | @tsv' "$body")

  if (( max_seen > WATERMARK )); then
    WATERMARK=$max_seen
    PROCESSED_AT_WATERMARK=()
    write_watermark
  fi
}

reconcile_due() {
  if [[ ! -e "$STATE_DIR/reconciled_at" ]]; then
    if [[ "$RECONCILE_ON_START" == true ]]; then
      return 0
    fi
    # No reconcile has ever run and we were told not to force one on start:
    # seed the interval clock at "now" rather than falling through to the
    # interval math below with a last=0 baseline, which would make "never
    # reconciled" look like "infinitely overdue" and force one anyway.
    printf '%s\n' "$EPOCHSECONDS" > "$STATE_DIR/reconciled_at"
    return 1
  fi
  local now=$EPOCHSECONDS last=0
  IFS= read -r last < "$STATE_DIR/reconciled_at" || true
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( now - last >= RECONCILE_INTERVAL ))
}

# reconcile — self-heals torrents that were missed (e.g. added during
# downtime) or whose trackers predate the current merged list. Reuses the
# same snapshot scan_new used this iteration; only the per-chunk
# trackerList fetch below is a new RPC call, chunked because a full
# library's tracker data is tens of MB of JSON.
reconcile() {
  log_info "reconcile: starting (scope=$RECONCILE_SCOPE)"

  local body="$STATE_DIR/snapshot.json"
  if [[ ! -s "$body" ]]; then
    log_warn "reconcile: no snapshot available, skipping this pass"
    return 0
  fi

  local jq_filter='.arguments.torrents[]'
  if [[ "$SKIP_PRIVATE" == true ]]; then
    jq_filter+=' | select(.isPrivate != true)'
  fi
  if [[ "$RECONCILE_SCOPE" == active ]]; then
    jq_filter+=' | select(.status >= 3 and .status <= 6)'
  fi
  jq_filter+=' | .hashString'

  local -a hashes=()
  local h
  while IFS= read -r h; do
    [[ -n "$h" ]] && hashes+=("$h")
  done < <(jq -r "$jq_filter" "$body")

  log_debug "reconcile: ${#hashes[@]} torrent(s) in scope"

  local merged_sha=""
  [[ -r "$STATE_DIR/merged.sha" ]] && { IFS= read -r merged_sha < "$STATE_DIR/merged.sha" || true; }

  local i=0 n=${#hashes[@]}
  while (( i < n )); do
    local -a chunk=("${hashes[@]:i:RECONCILE_CHUNK}")
    reconcile_chunk "$merged_sha" "${chunk[@]}"
    i=$(( i + RECONCILE_CHUNK ))
  done

  printf '%s\n' "$EPOCHSECONDS" > "$STATE_DIR/reconciled_at"
  log_info "reconcile: complete"
}

# reconcile_chunk MERGED_SHA HASH...
# Missing-tracker detection is a plain string set-difference (no URL
# normalizer) — see the design notes in the README for why. The memo file,
# keyed on "<hash> <merged_sha>", bounds churn to once per affected torrent
# per list change rather than once per reconcile pass.
reconcile_chunk() {
  local merged_sha=$1; shift
  local -a chunk=("$@")
  (( ${#chunk[@]} > 0 )) || return 0

  local ids_json
  ids_json=$(printf '%s\n' "${chunk[@]}" | jq -R . | jq -sc .)

  local fields='["hashString","name"'
  if [[ "$HAVE_TRACKER_LIST" == true ]]; then
    fields+=',"trackerList"'
  else
    fields+=',"trackers"'
  fi
  fields+=']'

  local args
  args=$(jq -cn --argjson ids "$ids_json" --argjson f "$fields" '{ids:$ids, fields:$f}')

  local rc=0
  rpc_call torrent-get "$args" || rc=$?
  if (( rc != 0 )); then
    log_warn "reconcile_chunk: torrent-get failed (rc=$rc), skipping this chunk"
    return 0
  fi

  local body="$STATE_DIR/resp.json"
  local hash name existing_raw
  while IFS=$'\t' read -r hash name existing_raw; do
    [[ -n "$hash" ]] || continue

    if grep -qFx "$hash $merged_sha" "$STATE_DIR/memo" 2>/dev/null; then
      log_debug "reconcile: \"$name\" ($hash) already reconciled at this list version"
      continue
    fi

    local existing_file="$STATE_DIR/reconcile_existing.txt"
    printf '%s\n' "$existing_raw" | tr ' ' '\n' | grep -v '^$' | sort -u > "$existing_file" || true

    # comm(1) is not a busybox applet and coreutils is deliberately not
    # installed — `grep -vFxf` gives the same set-difference (lines of
    # merged.txt not present verbatim in existing_file) without it.
    local missing
    missing=$(grep -vFxf "$existing_file" "$STATE_DIR/merged.txt") || true

    if [[ -z "$missing" ]]; then
      log_debug "reconcile: \"$name\" ($hash) already has every tracker in the list"
    else
      local missing_count
      missing_count=$(printf '%s\n' "$missing" | grep -c .) || true
      log_info "reconcile: \"$name\" ($hash) is missing $missing_count tracker(s)"
      if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY_RUN] would add $missing_count tracker(s) to \"$name\" ($hash)"
      else
        local args2 rc2=0
        args2=$(jq -cn --arg h "$hash" --arg m "$missing" \
            '{ids:[$h], trackerAdd:($m | split("\n") | map(select(length>0)))}')
        rpc_call torrent-set "$args2" || rc2=$?
        case $rc2 in
          0)  log_info "reconcile: \"$name\" ($hash): trackers applied" ;;
          10) log_info "reconcile: \"$name\" ($hash): daemon reported no change (check for a scheme or spelling mismatch)" ;;
          *)  log_warn "reconcile: \"$name\" ($hash): apply failed (rc=$rc2)" ;;
        esac
      fi
    fi

    printf '%s %s\n' "$hash" "$merged_sha" >> "$STATE_DIR/memo"
  done < <(jq -r --arg tl "$HAVE_TRACKER_LIST" '
      .arguments.torrents[] |
      [.hashString, .name,
       (if $tl == "true"
        then ((.trackerList // "") | gsub("\n"; " "))
        else ([.trackers[]?.announce] | join(" "))
        end)] | @tsv' "$body")
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

RUNNING=1
SLEEP_PID=""

on_signal() {
  RUNNING=0
  log_info "signal received, shutting down"
  if [[ -n "$SLEEP_PID" ]]; then
    kill "$SLEEP_PID" 2>/dev/null || true
  fi
}

# A foreground `sleep` does not yield to a trap; `wait` does. This is the
# entire reason `docker stop` can return promptly instead of waiting out
# the full grace period and being SIGKILLed. Every sleep in this program
# goes through this function — a bare `sleep` elsewhere is a bug.
interruptible_sleep() {
  local n=$1 rc=0
  (( RUNNING )) || return 0
  sleep "$n" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" || rc=$?
  SLEEP_PID=""
  return 0
}

heartbeat() {
  printf '%s\n' "$EPOCHSECONDS" > "$STATE_DIR/heartbeat"
}

# Liveness, not success: written every completed pass, including passes
# where the daemon was unreachable or the tracker list was unusable. A
# Transmission outage must not make this container flap unhealthy.
healthcheck_mode() {
  local state_dir=${STATE_DIR:-/tmp/ttaa}
  local max_age=${HEALTH_MAX_AGE:-$(( ${INTERVAL:-60} * 3 + 60 ))}
  local beat_at=0
  [[ -r "$state_dir/heartbeat" ]] && { IFS= read -r beat_at < "$state_dir/heartbeat" || true; }
  [[ "$beat_at" =~ ^[0-9]+$ ]] || exit 1
  (( EPOCHSECONDS - beat_at <= max_age )) || exit 1
  exit 0
}

main() {
  if [[ "${1:-}" == "--healthcheck" ]]; then
    healthcheck_mode
  fi

  load_config
  load_credentials
  resolve_list_urls
  banner

  mkdir -p "$STATE_DIR/lists"

  trap on_signal TERM INT

  wait_for_daemon
  assert_rpc_version

  read_watermark
  if [[ "$WATERMARK" -eq 0 ]]; then
    # Cold start: no persisted watermark (fresh tmpfs). Start the
    # incremental scan from "now" rather than backfilling every existing
    # torrent on every container restart — full-library coverage is
    # delegated to the reconcile pass instead.
    if refresh_snapshot; then
      local max_added
      max_added=$(jq -r '[.arguments.torrents[].addedDate // 0] | max // 0' "$STATE_DIR/snapshot.json")
      [[ "$max_added" =~ ^[0-9]+$ ]] || max_added=0
      WATERMARK=$max_added
      write_watermark
      log_info "cold start: watermark set to now ($WATERMARK); full-library coverage delegated to reconcile"
    fi
  fi

  maybe_refresh_lists || true

  while (( RUNNING )); do
    maybe_refresh_lists || true

    if [[ -s "$STATE_DIR/merged.txt" ]]; then
      if refresh_snapshot; then
        scan_new
        if reconcile_due; then
          reconcile
        fi
      else
        log_warn "skipping this pass: could not refresh the torrent snapshot"
      fi
    else
      log_warn "skipping this pass: no usable tracker list yet"
    fi

    heartbeat
    interruptible_sleep "$INTERVAL"
  done

  log_info "exited cleanly"
}

# Allows the function library to be sourced for testing without running
# main(): `TTAA_LIB_ONLY=1 source tracker-add.sh` then call functions
# directly against fixture files.
if [[ -z "${TTAA_LIB_ONLY:-}" ]]; then
  main "$@"
fi
