#!/usr/bin/env bash
#
# One-time setup of the OpenTofu state bucket in Vultr Object Storage.
#
# Vultr-native: VULTR_API_KEY is the only credential, and every call goes to
# api.vultr.com. There is no AWS account, no AWS CLI, and no AWS service in
# this path -- Vultr exposes bucket management directly under
# /v2/object-storage/{id}/bucket, and hands back the S3-protocol keys that
# OpenTofu needs in order to speak to *.vultrobjects.com.
#
#   export VULTR_API_KEY=...
#   scripts/bootstrap-backend.sh --bucket containerlabs-tfstate
#
# Idempotent: re-running against an existing bucket just rewrites backend.hcl.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib.sh
. "${ROOT}/scripts/lib.sh"

BUCKET="containerlabs-tfstate"
SUBSCRIPTION=""
REGION="us-east-1"
VERSIONING=1
WRITE_BACKEND_FILE=1
PRINT_SECRETS=0
LIST_ONLY=0

usage() {
  cat <<'EOF'
Usage: bootstrap-backend.sh [options]

  --bucket NAME         Bucket to hold OpenTofu state (default: containerlabs-tfstate)
  --subscription NAME   Object Storage subscription, by label or ID.
                        Optional when the account has exactly one.
  --region REGION       SigV4 signing region (default: us-east-1). Vultr ignores
                        it; it does not need to match your cluster.
  --no-versioning       Do not request bucket versioning.
  --print-secrets       Print the S3 keys, for pasting into GitHub secrets.
  --no-write            Do not generate backend.hcl.
  --list                Just list subscriptions and their buckets, then exit.

Environment:
  VULTR_API_KEY   required, and the only credential used.
EOF
}

while (($#)); do
  case "$1" in
    --bucket)         BUCKET="$2"; shift 2 ;;
    --subscription)   SUBSCRIPTION="$2"; shift 2 ;;
    --region)         REGION="$2"; shift 2 ;;
    --no-versioning)  VERSIONING=0; shift ;;
    --print-secrets)  PRINT_SECRETS=1; shift ;;
    --no-write)       WRITE_BACKEND_FILE=0; shift ;;
    --list)           LIST_ONLY=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; die "unknown argument: $1" ;;
  esac
done

require_cmd curl jq
require_env VULTR_API_KEY

# --- find the object storage subscription ------------------------------------

subs="$(vultr_api_paged /object-storage object_storages)"
sub_count="$(jq 'length' <<<"$subs")"

if ((LIST_ONLY)); then
  if ((sub_count == 0)); then
    log "no Object Storage subscriptions in this account."
    exit 0
  fi
  jq -r '.[] | "\(.label)\t\(.id)\t\(.region)\t\(.status)\t\(.s3_hostname)"' <<<"$subs" |
    while IFS=$'\t' read -r label id region status host; do
      printf '%s  (%s)\n  region=%s status=%s host=%s\n' "$label" "$id" "$region" "$status" "$host"
      vultr_api GET "/object-storage/${id}/bucket" |
        jq -r '(.buckets // []) | if length == 0 then "  buckets: (none)" else "  buckets: " + (map(.name) | join(", ")) end'
    done
  exit 0
fi

if ((sub_count == 0)); then
  log "This account has no Vultr Object Storage subscription yet."
  log ""
  log "Create one in the portal under Products -> Objects, then re-run this script."
  log "Available clusters:"
  vultr_api GET /object-storage/clusters |
    jq -r '(.clusters // [])[] | "  \(.id)\t\(.region)\t\(.hostname)"' >&2 || true
  die "no object storage subscription"
fi

if [[ -n $SUBSCRIPTION ]]; then
  sub="$(jq -c --arg s "$SUBSCRIPTION" \
    'map(select(.id == $s or .label == $s)) | .[0] // empty' <<<"$subs")"
  [[ -n $sub ]] || {
    log "no subscription matches '${SUBSCRIPTION}'. Available:"
    jq -r '.[] | "  \(.label)  \(.id)"' <<<"$subs" >&2
    die "unknown subscription: ${SUBSCRIPTION}"
  }
elif ((sub_count == 1)); then
  sub="$(jq -c '.[0]' <<<"$subs")"
else
  log "This account has ${sub_count} Object Storage subscriptions. Pick one with --subscription:"
  jq -r '.[] | "  \(.label)  \(.id)  \(.region)"' <<<"$subs" >&2
  die "ambiguous subscription"
fi

os_id="$(jq -r '.id' <<<"$sub")"
os_label="$(jq -r '.label' <<<"$sub")"
os_status="$(jq -r '.status' <<<"$sub")"
s3_host="$(jq -r '.s3_hostname' <<<"$sub")"
s3_access="$(jq -r '.s3_access_key' <<<"$sub")"
s3_secret="$(jq -r '.s3_secret_key' <<<"$sub")"

log "using subscription '${os_label}' (${os_id}), host ${s3_host}"

[[ $os_status == active ]] || warn "subscription status is '${os_status}', not 'active'; bucket operations may fail."

[[ -n $s3_host && $s3_host != null ]] || die "subscription returned no s3_hostname"

# The API returns a bare host; the backend wants a URL.
endpoint="https://${s3_host}"

# --- create the bucket -------------------------------------------------------

existing="$(vultr_api GET "/object-storage/${os_id}/bucket" | jq -r '(.buckets // [])[].name')"

if grep -qxF "$BUCKET" <<<"$existing"; then
  log "bucket '${BUCKET}' already exists"
else
  if ((VERSIONING)); then
    log "creating bucket '${BUCKET}' with versioning"
    body="$(jq -nc --arg n "$BUCKET" '{name: $n, enable_bucket_versioning: true}')"
  else
    log "creating bucket '${BUCKET}'"
    body="$(jq -nc --arg n "$BUCKET" '{name: $n}')"
  fi

  if ! out="$(vultr_api POST "/object-storage/${os_id}/bucket" "$body" 2>&1)"; then
    log "$out"
    log ""
    log "If the endpoint is unavailable on this account, create the bucket by hand:"
    log "  Vultr portal -> Objects -> ${os_label} -> Buckets -> Add Bucket -> '${BUCKET}'"
    die "could not create bucket '${BUCKET}'"
  fi

  log "bucket '${BUCKET}' created"
fi

# --- write backend.hcl -------------------------------------------------------

if ((WRITE_BACKEND_FILE)); then
  cat >"${ROOT}/backend.hcl" <<EOF
# Generated by scripts/bootstrap-backend.sh -- gitignored.
# Points OpenTofu's S3-protocol backend at Vultr Object Storage.
# Credentials are NOT here; they come from the environment.

bucket = "${BUCKET}"
region = "${REGION}"

endpoints = {
  s3 = "${endpoint}"
}
EOF
  log "wrote ${ROOT}/backend.hcl"
fi

# --- next steps --------------------------------------------------------------

cat <<EOF

Bucket ready in Vultr Object Storage.

Run locally:

  export VULTR_API_KEY=...
  # The S3-protocol keys below. These variable names come from the AWS SDK that
  # OpenTofu's s3 backend is built on -- the values are your Vultr keys and the
  # traffic goes to ${s3_host}.
  export AWS_ACCESS_KEY_ID='${s3_access}'
  export AWS_SECRET_ACCESS_KEY='<see --print-secrets>'

  tofu init -backend-config=backend.hcl

GitHub Actions -- Settings -> Secrets and variables -> Actions:

  secret   VULTR_API_KEY        your Vultr API key
  secret   TFSTATE_ACCESS_KEY   ${s3_access}
  secret   TFSTATE_SECRET_KEY   (run again with --print-secrets)
  variable TFSTATE_BUCKET       ${BUCKET}
  variable TFSTATE_REGION       ${REGION}
  variable TFSTATE_ENDPOINT     ${endpoint}
EOF

if ((PRINT_SECRETS)); then
  cat <<EOF

S3 keys for subscription '${os_label}':
  access key: ${s3_access}
  secret key: ${s3_secret}
EOF
fi
