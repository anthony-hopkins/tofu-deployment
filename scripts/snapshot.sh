#!/usr/bin/env bash
#
# Snapshot management for the containerlabs fleet.
#
# Snapshots are deliberately NOT OpenTofu resources. Taking one is an event, not
# a piece of desired state: modelling it as a resource means every snapshot you
# ever take stays in state forever and each new one is a config edit. Driving
# the Vultr API directly keeps state clean, lets snapshots outlive the stack,
# and makes retention a simple loop. Restores are still declarative -- put the
# snapshot ID in instances.auto.tfvars and apply.
#
# Snapshots created here are described as:  <project>/<instance>/<UTC stamp>
# That prefix is what `list` and `prune` key off, so snapshots taken by hand in
# the Vultr portal are left strictly alone.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib.sh
. "${ROOT}/scripts/lib.sh"

PROJECT="${PROJECT:-containerlabs}"

usage() {
  cat <<'EOF'
Usage: snapshot.sh <command> [options]

Commands:
  create (--instance NAME | --all) [--note TEXT] [--wait] [--timeout SECONDS]
         [--if-exists]
      Snapshot one instance, or every instance in the project with --all.
      NAME may be the tfvars key (lab01), the full label, the hostname, or a
      raw Vultr instance UUID. --if-exists turns "no such instance" into a
      no-op instead of an error, for pre-apply safety snapshots.

  list [--instance NAME] [--all] [--json]
      Show snapshots. Defaults to this project's snapshots only; --all
      includes ones taken outside this tooling.

  prune --keep N [--older-than DAYS] [--instance NAME] [--yes] [--dry-run]
      Keep the N newest snapshots per instance. Of the remainder, delete
      those older than DAYS (if given) or all of them. Snapshot IDs
      referenced in any *.tfvars file are never deleted.

  delete --id SNAPSHOT_ID --yes
      Delete one snapshot by ID.

  wait --id SNAPSHOT_ID [--timeout SECONDS]
      Block until a snapshot finishes uploading.

Environment:
  VULTR_API_KEY   required
  PROJECT         project tag/prefix (default: containerlabs)
EOF
}

# --- helpers -----------------------------------------------------------------

# Snapshots this tooling created, newest first, as a JSON array with an added
# .instance field parsed out of the description.
project_snapshots() {
  vultr_api_paged /snapshots snapshots |
    jq -c --arg p "$PROJECT" '
      [ .[]
        | select(.description | startswith($p + "/"))
        | . + { instance: (.description | split("/")[1]) }
      ] | sort_by(.date_created) | reverse'
}

# Snapshot IDs pinned in tfvars. These are live restore targets; deleting one
# would break the next apply, so prune skips them unconditionally.
pinned_snapshot_ids() {
  grep -rhoE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    "${ROOT}"/*.tfvars "${ROOT}"/*.tfvars.json 2>/dev/null | sort -u || true
}

# --- commands ----------------------------------------------------------------

cmd_create() {
  local needle="" note="" wait=0 timeout=1800 all=0 if_exists=0
  while (($#)); do
    case "$1" in
      --instance)  needle="$2"; shift 2 ;;
      --all)       all=1; shift ;;
      --if-exists) if_exists=1; shift ;;
      --note)      note="$2"; shift 2 ;;
      --wait)      wait=1; shift ;;
      --timeout)   timeout="$2"; shift 2 ;;
      *) die "create: unknown argument: $1" ;;
    esac
  done

  if ((all)); then
    [[ -z $needle ]] || die "create: --all and --instance are mutually exclusive"

    # Iterate by instance ID: unambiguous, and immune to two instances sharing
    # a label.
    local ids=()
    mapfile -t ids < <(fleet_instances "$PROJECT" | jq -r '.[].id')

    if ((${#ids[@]} == 0)); then
      log "no instances in project '${PROJECT}'; nothing to snapshot"
      printf '_No instances to snapshot._\n\n' | summary
      return 0
    fi

    local i
    for i in "${ids[@]}"; do
      create_one "$i" "$note" "$wait" "$timeout"
    done
    return 0
  fi

  [[ -n $needle ]] || die "create: --instance or --all is required"

  # Used by the apply/destroy workflows, where the target may not exist yet.
  if ((if_exists)) && ! resolve_instance "$needle" "$PROJECT" >/dev/null 2>&1; then
    log "instance '${needle}' does not exist; skipping snapshot"
    printf '_No snapshot taken: instance `%s` does not exist yet._\n\n' "$needle" | summary
    return 0
  fi

  create_one "$needle" "$note" "$wait" "$timeout"
}

# create_one NEEDLE NOTE WAIT TIMEOUT
create_one() {
  local needle="$1" note="$2" wait="$3" timeout="$4"
  local inst id label key stamp description resp snap_id
  inst="$(resolve_instance "$needle" "$PROJECT")"
  id="$(jq -r '.id' <<<"$inst")"
  label="$(jq -r '.label' <<<"$inst")"

  # The tfvars key, not the label: descriptions group by key so prune can
  # apply per-instance retention regardless of how the label is written.
  key="$(instance_key <<<"$inst")"

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  description="${PROJECT}/${key}/${stamp}"
  [[ -n $note ]] && description="${description} ${note}"

  log "snapshotting ${label} (${id}) as '${description}'"

  resp="$(vultr_api POST /snapshots \
    "$(jq -nc --arg i "$id" --arg d "$description" \
        '{instance_id: $i, description: $d}')")"

  snap_id="$(jq -r '.snapshot.id' <<<"$resp")"
  [[ -n $snap_id && $snap_id != null ]] || die "Vultr accepted the request but returned no snapshot ID"

  set_output snapshot_id "$snap_id"
  set_output description "$description"

  if ((wait)); then
    cmd_wait --id "$snap_id" --timeout "$timeout"
  fi

  local final
  final="$(vultr_api GET "/snapshots/${snap_id}" | jq -r '.snapshot.status')"

  {
    printf '## Snapshot created\n\n'
    printf '| Field | Value |\n|---|---|\n'
    printf '| Instance | `%s` (`%s`) |\n' "$label" "$id"
    printf '| Snapshot ID | `%s` |\n' "$snap_id"
    printf '| Description | `%s` |\n' "$description"
    printf '| Status | `%s` |\n\n' "$final"
    printf 'Restore by setting `snapshot_id = "%s"` on an instance in `instances.auto.tfvars`, then running the apply workflow.\n' "$snap_id"
  } | summary
}

cmd_list() {
  local needle="" all=0 as_json=0
  while (($#)); do
    case "$1" in
      --instance) needle="$2"; shift 2 ;;
      --all)      all=1; shift ;;
      --json)     as_json=1; shift ;;
      *) die "list: unknown argument: $1" ;;
    esac
  done

  local snaps
  if ((all)); then
    snaps="$(vultr_api_paged /snapshots snapshots |
      jq -c 'sort_by(.date_created) | reverse | map(. + {instance: "-"})')"
  else
    snaps="$(project_snapshots)"
  fi

  if [[ -n $needle ]]; then
    snaps="$(jq -c --arg n "$needle" '[.[] | select(.instance == $n)]' <<<"$snaps")"
  fi

  if ((as_json)); then
    jq '.' <<<"$snaps"
    return 0
  fi

  local count
  count="$(jq 'length' <<<"$snaps")"

  {
    printf '## Snapshots (%s)\n\n' "$count"
    if ((count == 0)); then
      printf '_None found._\n'
    else
      printf '| Created | Instance | Description | Size | Status | ID |\n'
      printf '|---|---|---|---|---|---|\n'
      jq -r '.[] | [
        .date_created, .instance, .description,
        (if .size then (.size/1073741824*10|round/10|tostring) + " GiB" else "-" end),
        .status, .id
      ] | @tsv' <<<"$snaps" |
        while IFS=$'\t' read -r created instance desc size status id; do
          printf '| %s | `%s` | %s | %s | %s | `%s` |\n' \
            "$created" "$instance" "$desc" "$size" "$status" "$id"
        done
    fi
    printf '\n'
  } | summary
}

cmd_prune() {
  local keep="" older_than="" needle="" yes=0 dry=0
  while (($#)); do
    case "$1" in
      --keep)       keep="$2"; shift 2 ;;
      --older-than) older_than="$2"; shift 2 ;;
      --instance)   needle="$2"; shift 2 ;;
      --yes)        yes=1; shift ;;
      --dry-run)    dry=1; shift ;;
      *) die "prune: unknown argument: $1" ;;
    esac
  done
  [[ -n $keep ]] || die "prune: --keep is required"
  [[ $keep =~ ^[0-9]+$ ]] || die "prune: --keep must be a non-negative integer"

  local snaps pinned cutoff=0
  snaps="$(project_snapshots)"
  [[ -n $needle ]] && snaps="$(jq -c --arg n "$needle" '[.[] | select(.instance == $n)]' <<<"$snaps")"

  pinned="$(pinned_snapshot_ids)"

  if [[ -n $older_than ]]; then
    [[ $older_than =~ ^[0-9]+$ ]] || die "prune: --older-than must be a whole number of days"
    cutoff="$(date -u -d "${older_than} days ago" +%s)"
  fi

  # Rank each snapshot within its instance group, newest = 0. Anything ranked
  # below --keep is a deletion candidate.
  local candidates
  candidates="$(jq -c --argjson keep "$keep" '
    group_by(.instance)
    | map(sort_by(.date_created) | reverse | to_entries
          | map(.value + {rank: .key}))
    | flatten
    | [ .[] | select(.rank >= $keep) ]' <<<"$snaps")"

  local -a to_delete=() skipped=()
  local id created desc instance created_epoch

  while IFS=$'\t' read -r id created desc instance; do
    [[ -n $id ]] || continue

    if grep -qxF "$id" <<<"$pinned"; then
      skipped+=("$id	$desc	pinned in tfvars")
      continue
    fi

    if ((cutoff > 0)); then
      created_epoch="$(date -u -d "$created" +%s 2>/dev/null || echo 0)"
      if ((created_epoch == 0)); then
        skipped+=("$id	$desc	unparseable date_created '$created'")
        continue
      fi
      if ((created_epoch >= cutoff)); then
        skipped+=("$id	$desc	newer than ${older_than}d")
        continue
      fi
    fi

    to_delete+=("$id	$desc	$instance")
  done < <(jq -r '.[] | [.id, .date_created, .description, .instance] | @tsv' <<<"$candidates")

  {
    printf '## Snapshot prune\n\n'
    printf -- '- keep newest **%s** per instance\n' "$keep"
    [[ -n $older_than ]] && printf -- '- delete only if older than **%s days**\n' "$older_than"
    [[ -n $needle    ]] && printf -- '- limited to instance `%s`\n' "$needle"
    ((dry)) && printf -- '- **dry run** -- nothing will be deleted\n'
    printf '\n'

    if ((${#to_delete[@]} == 0)); then
      printf 'Nothing to delete.\n\n'
    else
      printf '### To delete (%s)\n\n| ID | Description |\n|---|---|\n' "${#to_delete[@]}"
      local row
      for row in "${to_delete[@]}"; do
        IFS=$'\t' read -r id desc _ <<<"$row"
        printf '| `%s` | %s |\n' "$id" "$desc"
      done
      printf '\n'
    fi

    if ((${#skipped[@]} > 0)); then
      printf '### Retained despite exceeding --keep (%s)\n\n| ID | Description | Reason |\n|---|---|---|\n' "${#skipped[@]}"
      local reason
      for row in "${skipped[@]}"; do
        IFS=$'\t' read -r id desc reason <<<"$row"
        printf '| `%s` | %s | %s |\n' "$id" "$desc" "$reason"
      done
      printf '\n'
    fi
  } | summary

  ((${#to_delete[@]} > 0)) || return 0

  if ((dry)); then
    log "dry run: would delete ${#to_delete[@]} snapshot(s)"
    return 0
  fi

  ((yes)) || die "prune: refusing to delete ${#to_delete[@]} snapshot(s) without --yes"

  local row
  for row in "${to_delete[@]}"; do
    IFS=$'\t' read -r id desc _ <<<"$row"
    log "deleting ${id} (${desc})"
    vultr_api DELETE "/snapshots/${id}" >/dev/null
  done

  log "deleted ${#to_delete[@]} snapshot(s)"
  printf 'Deleted **%s** snapshot(s).\n\n' "${#to_delete[@]}" | summary
}

cmd_delete() {
  local id="" yes=0
  while (($#)); do
    case "$1" in
      --id)  id="$2"; shift 2 ;;
      --yes) yes=1; shift ;;
      *) die "delete: unknown argument: $1" ;;
    esac
  done
  [[ -n $id ]] || die "delete: --id is required"
  ((yes)) || die "delete: --yes is required"

  if grep -qxF "$id" <<<"$(pinned_snapshot_ids)"; then
    die "refusing to delete ${id}: it is referenced in a .tfvars file. Remove the reference first."
  fi

  local desc
  desc="$(vultr_api GET "/snapshots/${id}" | jq -r '.snapshot.description')"
  vultr_api DELETE "/snapshots/${id}" >/dev/null

  log "deleted ${id} (${desc})"
  printf '## Snapshot deleted\n\n`%s` -- %s\n\n' "$id" "$desc" | summary
}

cmd_wait() {
  local id="" timeout=1800
  while (($#)); do
    case "$1" in
      --id)      id="$2"; shift 2 ;;
      --timeout) timeout="$2"; shift 2 ;;
      *) die "wait: unknown argument: $1" ;;
    esac
  done
  [[ -n $id ]] || die "wait: --id is required"

  local deadline status elapsed=0 interval=15
  deadline=$((SECONDS + timeout))

  while ((SECONDS < deadline)); do
    status="$(vultr_api GET "/snapshots/${id}" | jq -r '.snapshot.status')"
    case "$status" in
      complete)
        log "snapshot ${id} complete after ~${elapsed}s"
        return 0
        ;;
      pending)
        log "snapshot ${id} still pending (~${elapsed}s elapsed)"
        ;;
      *)
        die "snapshot ${id} entered unexpected status '${status}'"
        ;;
    esac
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  die "timed out after ${timeout}s waiting for snapshot ${id}"
}

# --- dispatch ----------------------------------------------------------------

require_cmd curl jq
require_env VULTR_API_KEY

(($# > 0)) || { usage >&2; exit 2; }

command="$1"; shift
case "$command" in
  create) cmd_create "$@" ;;
  list)   cmd_list   "$@" ;;
  prune)  cmd_prune  "$@" ;;
  delete) cmd_delete "$@" ;;
  wait)   cmd_wait   "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; die "unknown command: $command" ;;
esac
