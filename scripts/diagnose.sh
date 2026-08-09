#!/usr/bin/env bash
#
# Read-only health report for the containerlabs fleet.
#
# Makes no changes to anything. Exits non-zero when it finds a problem, so the
# workflow goes red and shows up in the Actions list without anyone reading the
# log. Pass --no-fail to always exit 0.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib.sh
. "${ROOT}/scripts/lib.sh"

PROJECT="${PROJECT:-containerlabs}"

NEEDLE=""
PORTS="22"
MAX_SNAPSHOT_AGE_DAYS=""
FAIL_ON_PROBLEM=1
PROBLEMS=0

usage() {
  cat <<'EOF'
Usage: diagnose.sh [options]

  --instance NAME          Limit the report to one instance.
  --ports LIST             Comma-separated TCP ports to probe (default: 22).
  --max-snapshot-age DAYS  Flag instances whose newest snapshot is older.
  --no-fail                Always exit 0, even when problems are found.

Environment:
  VULTR_API_KEY   required
  PROJECT         project tag/prefix (default: containerlabs)
EOF
}

while (($#)); do
  case "$1" in
    --instance)         NEEDLE="$2"; shift 2 ;;
    --ports)            PORTS="$2"; shift 2 ;;
    --max-snapshot-age) MAX_SNAPSHOT_AGE_DAYS="$2"; shift 2 ;;
    --no-fail)          FAIL_ON_PROBLEM=0; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

require_cmd curl jq timeout
require_env VULTR_API_KEY

problem() {
  PROBLEMS=$((PROBLEMS + 1))
  printf -- '- :x: %s\n' "$*"
}
ok() { printf -- '- :white_check_mark: %s\n' "$*"; }

# =============================================================================
# 1. Account and API reachability
# =============================================================================

account_section() {
  printf '## Account\n\n'

  local account name email balance pending credit
  if ! account="$(vultr_api GET /account 2>&1)"; then
    problem "Vultr API unreachable or the API key was rejected: ${account}"
    return 0
  fi

  name="$(jq -r '.account.name // "-"' <<<"$account")"
  email="$(jq -r '.account.email // "-"' <<<"$account")"
  balance="$(jq -r '.account.balance // 0' <<<"$account")"
  pending="$(jq -r '.account.pending_charges // 0' <<<"$account")"

  # Vultr reports prepaid credit as a NEGATIVE balance -- their own API example
  # is balance: -100.55 with pending_charges: 60.25. A POSITIVE balance is money
  # owed. Present it the way the portal does rather than raw.
  credit="$(awk "BEGIN{printf \"%.2f\", ($balance < 0) ? -($balance) : 0}")"

  printf '| Field | Value |\n|---|---|\n'
  printf '| Account | %s |\n' "$name"
  printf '| Email | %s |\n' "$email"
  printf '| Credit remaining | $%s |\n' "$credit"
  printf '| Pending charges | $%s |\n' "$pending"
  printf '| Raw API balance | %s |\n\n' "$balance"

  if awk "BEGIN{exit !($balance > 0)}"; then
    problem "Account owes \$${balance}. Instances can be suspended."
  elif awk "BEGIN{exit !($credit < $pending)}"; then
    problem "Credit remaining (\$${credit}) is below pending charges (\$${pending}); top up before it runs out."
  fi
}

# =============================================================================
# 2. Fleet inventory and state
# =============================================================================

FLEET=""

fleet_section() {
  printf '## Fleet\n\n'

  # Do not let an API hiccup here abort the whole report; the account section
  # has already recorded whether the API is answering at all.
  FLEET="$(fleet_instances "$PROJECT" 2>/dev/null)" || FLEET=""
  if [[ -z $FLEET ]]; then
    problem "Could not list instances from the Vultr API."
    printf '\n'
    return 0
  fi

  [[ -n $NEEDLE ]] && FLEET="$(jq -c --arg n "$NEEDLE" '
      [ .[] | select(.id == $n or .label == $n or .hostname == $n
                     or ((.tags // []) | index("instance:" + $n) != null)) ]' <<<"$FLEET")"

  local count
  count="$(jq 'length' <<<"$FLEET")"

  if ((count == 0)); then
    if [[ -n $NEEDLE ]]; then
      problem "No instance matching '${NEEDLE}' is tagged for project '${PROJECT}'."
    else
      printf '_No instances are currently tagged for project `%s`._\n\n' "$PROJECT"
      printf 'This is expected if you have not applied yet.\n\n'
    fi
    return 0
  fi

  printf '| Key | Label | Region | Plan | vCPU/RAM | Main IP | Status | Power | Server |\n'
  printf '|---|---|---|---|---|---|---|---|---|\n'
  jq -r '.[]
    | (((.tags // []) | map(select(startswith("instance:"))) | first // "?") | ltrimstr("instance:")) as $k
    | [
    $k, .label, .region, .plan, "\(.vcpu_count)c/\(.ram)MB",
    (if .main_ip == "" or .main_ip == "0.0.0.0" then (.v6_main_ip // "-") else .main_ip end),
    .status, .power_status, .server_status
  ] | @tsv' <<<"$FLEET" |
    while IFS=$'\t' read -r key label region plan size ip status power server; do
      printf '| `%s` | %s | %s | %s | %s | `%s` | %s | %s | %s |\n' \
        "$key" "$label" "$region" "$plan" "$size" "$ip" "$status" "$power" "$server"
    done
  printf '\n'

  # Flag anything not in the healthy triple. server_status is "none" until the
  # guest agent reports in, which is normal for a few minutes after create.
  local label status power server
  while IFS=$'\t' read -r label status power server; do
    [[ -n $label ]] || continue
    [[ $status == active   ]] || problem "\`${label}\` subscription status is \`${status}\` (expected \`active\`)."
    [[ $power  == running  ]] || problem "\`${label}\` is powered \`${power}\`."
    case "$server" in
      ok|installingbooting|none) ;;
      *) problem "\`${label}\` server status is \`${server}\`." ;;
    esac
  done < <(jq -r '.[] | [.label, .status, .power_status, .server_status] | @tsv' <<<"$FLEET")

  printf '\n'
}

# =============================================================================
# 3. Network reachability
# =============================================================================

reachability_section() {
  [[ -n $FLEET ]] || return 0
  local count
  count="$(jq 'length' <<<"$FLEET")"
  ((count > 0)) || return 0

  printf '## Reachability\n\n'
  printf '| Instance | Address | Port | Result |\n|---|---|---|---|\n'

  local label ip port result
  while IFS=$'\t' read -r label ip; do
    [[ -n $label ]] || continue

    if [[ -z $ip || $ip == "0.0.0.0" || $ip == "-" ]]; then
      printf '| `%s` | _no public IPv4_ | - | skipped |\n' "$label"
      continue
    fi

    IFS=',' read -ra port_list <<<"$PORTS"
    for port in "${port_list[@]}"; do
      port="${port// /}"
      [[ -n $port ]] || continue
      if tcp_check "$ip" "$port" 5; then
        result=':white_check_mark: open'
      else
        result=':x: closed/filtered'
        PROBLEMS=$((PROBLEMS + 1))
      fi
      printf '| `%s` | `%s` | %s | %s |\n' "$label" "$ip" "$port" "$result"
    done
  done < <(jq -r '.[] | [.label, .main_ip] | @tsv' <<<"$FLEET")

  printf '\n'
  printf '_A closed port is not always a fault: an instance still running cloud-init, '
  printf 'or one behind a firewall group that excludes GitHub runner IPs, will show closed._\n\n'
}

# =============================================================================
# 4. Snapshot coverage
# =============================================================================

snapshot_section() {
  printf '## Snapshots\n\n'

  local snaps count
  snaps="$(vultr_api_paged /snapshots snapshots |
    jq -c --arg p "$PROJECT" '
      [ .[] | select(.description | startswith($p + "/"))
            | . + { instance: (.description | split("/")[1]) } ]')"

  count="$(jq 'length' <<<"$snaps")"

  if ((count == 0)); then
    printf '_No snapshots exist for project `%s`._\n\n' "$PROJECT"
  else
    printf '| Instance | Count | Newest | Age | Total size |\n|---|---|---|---|---|\n'

    local instance n newest total age_days newest_epoch now
    now="$(date -u +%s)"

    while IFS=$'\t' read -r instance n newest total; do
      [[ -n $instance ]] || continue
      newest_epoch="$(date -u -d "$newest" +%s 2>/dev/null || echo 0)"
      if ((newest_epoch > 0)); then
        age_days=$(((now - newest_epoch) / 86400))
      else
        age_days="?"
      fi

      printf '| `%s` | %s | %s | %s d | %s |\n' \
        "$instance" "$n" "$newest" "$age_days" "$(human_size "$total")"

      if [[ -n $MAX_SNAPSHOT_AGE_DAYS && $age_days != "?" ]] \
         && ((age_days > MAX_SNAPSHOT_AGE_DAYS)); then
        problem "\`${instance}\` newest snapshot is ${age_days} days old (limit ${MAX_SNAPSHOT_AGE_DAYS})."
      fi
    done < <(jq -r '
      group_by(.instance)
      | .[]
      | [ .[0].instance,
          length,
          (max_by(.date_created) | .date_created),
          (map(.size // 0) | add) ]
      | @tsv' <<<"$snaps")

    printf '\n'

    local pending
    pending="$(jq '[.[] | select(.status != "complete")] | length' <<<"$snaps")"
    ((pending == 0)) || printf '_%s snapshot(s) still uploading._\n\n' "$pending"
  fi

  # Instances with no snapshot at all.
  if [[ -n $FLEET ]] && [[ -n $MAX_SNAPSHOT_AGE_DAYS ]]; then
    local label key
    while IFS=$'\t' read -r key label; do
      [[ -n $key ]] || continue
      if [[ "$(jq --arg k "$key" '[.[] | select(.instance == $k)] | length' <<<"$snaps")" == "0" ]]; then
        problem "\`${label}\` has no snapshots."
      fi
    done < <(jq -r '.[]
      | (((.tags // []) | map(select(startswith("instance:"))) | first // "") | ltrimstr("instance:")) as $k
      | [$k, .label] | @tsv' <<<"$FLEET")

    printf '\n'
  fi
}

# =============================================================================
# 5. Unmanaged resources
# =============================================================================

unmanaged_section() {
  local all unmanaged count
  all="$(vultr_api_paged /instances instances)"
  unmanaged="$(jq -c '[.[] | select((.tags // []) | index("managed-by:opentofu") | not)]' <<<"$all")"
  count="$(jq 'length' <<<"$unmanaged")"

  ((count > 0)) || return 0

  printf '## Unmanaged instances (%s)\n\n' "$count"
  printf 'Present in the Vultr account but not tagged `managed-by:opentofu`, so this stack will never touch them. Listed in case one is an orphan from a failed run.\n\n'
  printf '| Label | Region | Plan | Main IP | Created |\n|---|---|---|---|---|\n'
  jq -r '.[] | [.label, .region, .plan, .main_ip, .date_created] | @tsv' <<<"$unmanaged" |
    while IFS=$'\t' read -r label region plan ip created; do
      printf '| `%s` | %s | %s | `%s` | %s |\n' "$label" "$region" "$plan" "$ip" "$created"
    done
  printf '\n'
}

# =============================================================================

# The report is built into a file rather than piped straight to summary(): a
# pipeline runs its left side in a subshell, and the PROBLEMS counter the
# section functions increment has to survive into the verdict below.
REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT

{
  printf '# containerlabs diagnostics\n\n'
  printf '_project `%s`, generated %s_\n\n' "$PROJECT" "$(date -u '+%Y-%m-%d %H:%M:%SZ')"

  account_section
  fleet_section
  reachability_section
  snapshot_section
  unmanaged_section

  printf '## Verdict\n\n'
  if ((PROBLEMS == 0)); then
    printf ':white_check_mark: **No problems found.**\n\n'
  else
    printf ':x: **%s problem(s) found.** See the annotated lines above.\n\n' "$PROBLEMS"
  fi
} >"$REPORT"

summary <"$REPORT"

set_output problems "$PROBLEMS"

if ((PROBLEMS > 0 && FAIL_ON_PROBLEM)); then
  exit 1
fi
exit 0
