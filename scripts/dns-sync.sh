#!/usr/bin/env bash
#
# Reconcile Cloudflare A and AAAA records with the fleet OpenTofu manages.
#
# Desired state comes from `tofu output -json dns_records` (hostname ->
# {A: ipv4, AAAA: ipv6}), so this runs anywhere the state is reachable -- no
# per-instance agents, no API token baked into cloud-init. For each record it
# creates the entry if missing, updates it if the IP (or TTL/proxied) drifted,
# and leaves it alone when already in sync.
#
# Every record this script writes is stamped with the Cloudflare record
# comment "managed-by:opentofu:<project>". --prune deletes records carrying
# that comment that the fleet no longer wants -- a destroyed instance's
# records, or the AAAA of a box whose IPv6 was turned off -- and nothing
# else: records created by hand are invisible to the prune by design.
#
# The zone is discovered per record: the script lists the zones the token can
# see and picks the longest one that is a suffix of the record name, so it
# works unchanged if dns_zone ever changes or a second zone appears.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib.sh
. "${ROOT}/scripts/lib.sh"

PROJECT="${PROJECT:-containerlabs}"

RECORDS_JSON=""
PRUNE=0
DRY_RUN=0
TTL=60
PROXIED=false

usage() {
  cat <<'EOF'
Usage: dns-sync.sh [options]

  --records-json FILE  Read the {"fqdn": {"A": ipv4, "AAAA": ipv6}} map from
                       FILE ("-" for stdin) instead of
                       `tofu output -json dns_records`.
  --prune              Delete A/AAAA records tagged
                       managed-by:opentofu:<project> that the fleet no longer
                       wants.
  --ttl SECONDS        TTL for created/updated records (default: 60).
  --proxied            Create records proxied through Cloudflare
                       (default: DNS only; forces TTL to auto).
  --dry-run            Print what would change without touching Cloudflare.

Environment:
  CLOUDFLARE_API_TOKEN  required; needs Zone:Read + DNS:Edit on the zone
  PROJECT               project tag, part of the ownership comment
                        (default: containerlabs)
EOF
}

while (($#)); do
  case "$1" in
    --records-json) RECORDS_JSON="$2"; shift 2 ;;
    --prune)        PRUNE=1; shift ;;
    --ttl)          TTL="$2"; shift 2 ;;
    --proxied)      PROXIED=true; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

require_cmd curl jq
require_env CLOUDFLARE_API_TOKEN

# Proxied records always resolve at Cloudflare's edge; the API wants ttl=1
# ("auto") and silently ignores anything else.
[[ "$PROXIED" == "true" ]] && TTL=1

COMMENT="managed-by:opentofu:${PROJECT}"

# --- desired state -----------------------------------------------------------

if [[ -n "$RECORDS_JSON" ]]; then
  if [[ "$RECORDS_JSON" == "-" ]]; then
    desired="$(cat)"
  else
    desired="$(cat "$RECORDS_JSON")"
  fi
else
  require_cmd tofu
  desired="$(tofu output -json dns_records 2>/dev/null)" ||
    die "could not read the dns_records output -- run from an initialised checkout, or pass --records-json"
fi

jq -e 'type == "object" and ([.[] | type == "object"] | all)' >/dev/null 2>&1 <<<"$desired" ||
  die "desired records are not a JSON object of {\"fqdn\": {\"A\": ipv4, \"AAAA\": ipv6}}"

count="$(jq '[.[] | length] | add // 0' <<<"$desired")"
if ((count == 0 && !PRUNE)); then
  log "no instances with a public IP -- nothing to sync"
  exit 0
fi

# --- zone discovery ----------------------------------------------------------

zones="$(cf_api_paged /zones | jq -c '[.[] | {id, name}]')"
((("$(jq 'length' <<<"$zones")") > 0)) ||
  die "the token cannot see any Cloudflare zones -- it needs Zone:Read"

# zone_for FQDN -- print "id name" of the longest zone that suffixes FQDN,
# nothing if none matches.
zone_for() {
  jq -r --arg fqdn "$1" '
    [ .[] | select(.name as $z | $fqdn == $z or ($fqdn | endswith("." + $z))) ]
    | sort_by(.name | length) | last // empty
    | "\(.id) \(.name)"' <<<"$zones"
}

# --- reconcile ---------------------------------------------------------------

ROWS=()
CREATED=0 UPDATED=0 UNCHANGED=0 PRUNED=0 FAILED=0

note() { # note FQDN TYPE IP ACTION
  ROWS+=("| \`$1\` | $2 | \`$3\` | $4 |")
}

while IFS=$'\t' read -r fqdn rtype ip; do
  zone="$(zone_for "$fqdn")"
  if [[ -z "$zone" ]]; then
    warn "no Cloudflare zone matches '${fqdn}' -- skipped"
    note "$fqdn" "$rtype" "$ip" ":x: no matching zone"
    FAILED=$((FAILED + 1))
    continue
  fi
  zone_id="${zone%% *}"

  body="$(jq -cn --arg type "$rtype" --arg name "$fqdn" --arg ip "$ip" --arg comment "$COMMENT" \
    --argjson ttl "$TTL" --argjson proxied "$PROXIED" \
    '{type: $type, name: $name, content: $ip, ttl: $ttl, proxied: $proxied, comment: $comment}')"

  existing="$(cf_api GET "/zones/${zone_id}/dns_records?type=${rtype}&name=${fqdn}" | jq -c '.result')"
  n="$(jq 'length' <<<"$existing")"
  ((n > 1)) && warn "'${fqdn}' has ${n} ${rtype} records; managing the first, leaving the rest alone"

  if ((n == 0)); then
    if ((DRY_RUN)); then
      note "$fqdn" "$rtype" "$ip" "would create"
    else
      cf_api POST "/zones/${zone_id}/dns_records" "$body" >/dev/null
      log "created ${fqdn} ${rtype} -> ${ip}"
      note "$fqdn" "$rtype" "$ip" "created"
    fi
    CREATED=$((CREATED + 1))
    continue
  fi

  record_id="$(jq -r '.[0].id' <<<"$existing")"
  in_sync="$(jq --arg ip "$ip" --argjson ttl "$TTL" --argjson proxied "$PROXIED" \
    '.[0] | .content == $ip and .ttl == $ttl and .proxied == $proxied' <<<"$existing")"

  if [[ "$in_sync" == "true" ]]; then
    note "$fqdn" "$rtype" "$ip" "in sync"
    UNCHANGED=$((UNCHANGED + 1))
  elif ((DRY_RUN)); then
    note "$fqdn" "$rtype" "$ip" "would update (was \`$(jq -r '.[0].content' <<<"$existing")\`)"
    UPDATED=$((UPDATED + 1))
  else
    cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$body" >/dev/null
    log "updated ${fqdn} ${rtype} -> ${ip}"
    note "$fqdn" "$rtype" "$ip" "updated"
    UPDATED=$((UPDATED + 1))
  fi
done < <(jq -r 'to_entries[] | .key as $n | .value | to_entries[] | [$n, .key, .value] | @tsv' <<<"$desired")

# --- prune -------------------------------------------------------------------

if ((PRUNE)); then
  comment_uri="$(jq -rn --arg c "$COMMENT" '$c | @uri')"

  while IFS=$'\t' read -r zone_id record_id fqdn rtype ip; do
    if ((DRY_RUN)); then
      note "$fqdn" "$rtype" "$ip" "would delete"
    else
      cf_api DELETE "/zones/${zone_id}/dns_records/${record_id}" >/dev/null
      log "deleted stale record ${fqdn} ${rtype} -> ${ip}"
      note "$fqdn" "$rtype" "$ip" "deleted"
    fi
    PRUNED=$((PRUNED + 1))
  done < <(
    jq -r '.[].id' <<<"$zones" | while read -r zid; do
      cf_api_paged "/zones/${zid}/dns_records?comment=${comment_uri}" |
        jq -r --arg zid "$zid" --argjson desired "$desired" '
          .[]
          | select(.type == "A" or .type == "AAAA")
          | select(.name as $n | .type as $t | ($desired[$n] // {}) | has($t) | not)
          | [$zid, .id, .name, .type, .content] | @tsv'
    done
  )
fi

# --- report ------------------------------------------------------------------

{
  echo "## DNS sync"
  echo
  ((DRY_RUN)) && echo "_Dry run -- nothing was changed._" && echo
  if ((${#ROWS[@]} == 0)); then
    echo "_Nothing to do._"
  else
    echo "| Record | Type | Content | Action |"
    echo "|---|---|---|---|"
    printf '%s\n' "${ROWS[@]}"
  fi
  echo
  echo "${CREATED} created, ${UPDATED} updated, ${UNCHANGED} in sync, ${PRUNED} pruned, ${FAILED} failed."
} | summary

((FAILED == 0)) || die "${FAILED} record(s) could not be synced"
