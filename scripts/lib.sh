#!/usr/bin/env bash
# Shared helpers for the containerlabs operational scripts.
# Source it, do not execute it:  . "$(dirname "$0")/lib.sh"

VULTR_API_BASE="${VULTR_API_BASE:-https://api.vultr.com/v2}"

# --- output ------------------------------------------------------------------

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Pipe markdown here. Lands in the GitHub Actions job summary when running in
# CI, on stdout when running locally.
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    tee -a "$GITHUB_STEP_SUMMARY"
  else
    cat
  fi
}

# set_output NAME VALUE -- expose a value as a workflow step output.
set_output() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
  printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

# --- preconditions -----------------------------------------------------------

require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

require_env() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || die "required environment variable $v is not set"
  done
}

# --- Vultr API ---------------------------------------------------------------

# vultr_api METHOD PATH [JSON_BODY]
# Writes the response body to stdout. Aborts on any non-2xx response, printing
# the Vultr error payload so failures are diagnosable from the run log.
vultr_api() {
  local method="$1" path="$2" body="${3:-}"
  local tmp status rc
  tmp="$(mktemp)"

  local args=(
    --silent --show-error
    --request "$method"
    --output "$tmp"
    --write-out '%{http_code}'
    --max-time 60
    --header "Authorization: Bearer ${VULTR_API_KEY}"
    --header "Content-Type: application/json"
  )
  [[ -n "$body" ]] && args+=(--data "$body")

  set +e
  status="$(curl "${args[@]}" "${VULTR_API_BASE}${path}")"
  rc=$?
  set -e

  if ((rc != 0)); then
    rm -f "$tmp"
    die "curl failed (exit $rc) for $method $path"
  fi

  if [[ $status != 2* ]]; then
    local detail
    detail="$(jq -r '.error // empty' <"$tmp" 2>/dev/null || true)"
    [[ -n "$detail" ]] || detail="$(head -c 500 <"$tmp")"
    rm -f "$tmp"
    die "Vultr API $method $path returned HTTP $status: ${detail:-<empty body>}"
  fi

  cat "$tmp"
  rm -f "$tmp"
}

# vultr_api_paged PATH KEY
# Follows Vultr's cursor pagination and prints a single JSON array of all
# elements found under KEY across every page.
vultr_api_paged() {
  local path="$1" key="$2"
  local cursor="" acc="[]" page sep

  while :; do
    local p="$path"
    [[ $p == *\?* ]] && sep='&' || sep='?'
    p="${p}${sep}per_page=500"
    [[ -n $cursor ]] && p="${p}&cursor=${cursor}"

    page="$(vultr_api GET "$p")"
    acc="$(jq -c --argjson acc "$acc" --arg k "$key" '$acc + (.[$k] // [])' <<<"$page")"

    cursor="$(jq -r '.meta.links.next // ""' <<<"$page")"
    [[ -n $cursor ]] || break
  done

  printf '%s\n' "$acc"
}

# --- Cloudflare API ----------------------------------------------------------

CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

# cf_api METHOD PATH [JSON_BODY]
# Writes the response body to stdout. Aborts on a non-2xx response or a
# `success: false` envelope, printing Cloudflare's error list so failures are
# diagnosable from the run log.
cf_api() {
  local method="$1" path="$2" body="${3:-}"
  local tmp status rc
  tmp="$(mktemp)"

  local args=(
    --silent --show-error
    --request "$method"
    --output "$tmp"
    --write-out '%{http_code}'
    --max-time 60
    --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
    --header "Content-Type: application/json"
  )
  [[ -n "$body" ]] && args+=(--data "$body")

  set +e
  status="$(curl "${args[@]}" "${CF_API_BASE}${path}")"
  rc=$?
  set -e

  if ((rc != 0)); then
    rm -f "$tmp"
    die "curl failed (exit $rc) for $method $path"
  fi

  # Cloudflare wraps everything in {success, errors, result}; a 2xx with
  # success=false does happen, so check both.
  if [[ $status != 2* ]] || [[ "$(jq -r '.success' <"$tmp" 2>/dev/null)" != "true" ]]; then
    local detail
    detail="$(jq -r '[.errors[]? | "\(.code): \(.message)"] | join("; ")' <"$tmp" 2>/dev/null || true)"
    [[ -n "$detail" ]] || detail="$(head -c 500 <"$tmp")"
    rm -f "$tmp"
    die "Cloudflare API $method $path returned HTTP $status: ${detail:-<empty body>}"
  fi

  cat "$tmp"
  rm -f "$tmp"
}

# cf_api_paged PATH
# Follows Cloudflare's page-number pagination and prints a single JSON array
# of every element found under `result` across all pages.
cf_api_paged() {
  local path="$1"
  local page=1 total=1 acc="[]" resp sep

  while ((page <= total)); do
    [[ $path == *\?* ]] && sep='&' || sep='?'
    resp="$(cf_api GET "${path}${sep}per_page=100&page=${page}")"

    acc="$(jq -c --argjson acc "$acc" '$acc + (.result // [])' <<<"$resp")"
    total="$(jq -r '.result_info.total_pages // 1' <<<"$resp")"
    page=$((page + 1))
  done

  printf '%s\n' "$acc"
}

# --- fleet lookup ------------------------------------------------------------

# fleet_instances [PROJECT]
# JSON array of the instances this project owns, identified by the
# managed-by:opentofu tag that main.tf stamps on every instance. Anything not
# carrying that tag is invisible to these scripts by design.
fleet_instances() {
  local project="${1:-${PROJECT:-containerlabs}}"
  vultr_api_paged /instances instances |
    jq -c --arg p "$project" '
      [ .[]
        | select((.tags // []) | index("managed-by:opentofu"))
        | select((.tags // []) | index($p))
      ]'
}

# instance_key -- read an instance object on stdin, print its tfvars key.
#
# The key comes from the `instance:<key>` tag that main.tf stamps on, not from
# the label: labels are DNS names now (lab01.dhs-labs.us) and are freely
# overridable per instance, so parsing them would be guesswork.
instance_key() {
  jq -r '
    ((.tags // []) | map(select(startswith("instance:"))) | first) as $t
    | if $t then ($t | ltrimstr("instance:")) else (.label // "") end'
}

# resolve_instance NEEDLE [PROJECT]
# Accepts a tfvars key (lab01), a full label or hostname (lab01.dhs-labs.us),
# or a raw Vultr instance UUID. Prints the instance object. Fails loudly on an
# ambiguous needle rather than picking one arbitrarily.
resolve_instance() {
  local needle="$1" project="${2:-${PROJECT:-containerlabs}}"
  local all matches count

  all="$(fleet_instances "$project")"
  matches="$(jq -c --arg n "$needle" '
    [ .[] | select(
        .id == $n
        or .label == $n
        or .hostname == $n
        or ((.tags // []) | index("instance:" + $n) != null)
      ) ]' <<<"$all")"

  count="$(jq 'length' <<<"$matches")"

  if ((count == 0)); then
    log "no instance in project '$project' matches '$needle'. Known instances:"
    jq -r '.[]
      | ((.tags // []) | map(select(startswith("instance:"))) | first // "?") as $t
      | "  \($t | ltrimstr("instance:"))\t\(.label)\t\(.id)\t\(.main_ip)"' <<<"$all" >&2
    die "unresolved instance: $needle"
  fi

  if ((count > 1)); then
    log "'$needle' is ambiguous in project '$project':"
    jq -r '.[] | "  \(.label)  \(.id)"' <<<"$matches" >&2
    die "ambiguous instance: $needle"
  fi

  jq -c '.[0]' <<<"$matches"
}

# --- misc --------------------------------------------------------------------

# tcp_check HOST PORT [TIMEOUT_SECONDS]
tcp_check() {
  local host="$1" port="$2" tmo="${3:-5}"
  timeout "$tmo" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# human_size BYTES -- Vultr reports snapshot sizes in bytes.
human_size() {
  numfmt --to=iec-i --suffix=B "${1:-0}" 2>/dev/null || printf '%s' "${1:-0}"
}
