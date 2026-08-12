# containerlabs

OpenTofu-managed Vultr compute instances for container labs, driven entirely
from manually-triggered GitHub Actions workflows.

Five operations, five workflows, all `workflow_dispatch`:

| Workflow | What it does | Touches state | Destructive |
|---|---|---|---|
| **1 · Plan** | Shows what an apply would change. Also runs on every PR. | read | no |
| **2 · Apply** | Creates new instances, updates existing ones. | write | no |
| **3 · Destroy** | Destroys one instance or the whole fleet. | write | **yes** |
| **4 · Snapshot** | Create / list / prune / delete snapshots. | none | prune & delete |
| **5 · Diagnose** | Health report: status, reachability, snapshot coverage, drift. | read (drift check only) | no |

The fleet is declared in [instances.auto.tfvars](instances.auto.tfvars). That
file is the source of truth: change it in a PR, read the plan the bot posts,
merge, then run **2 · Apply**.

**Setting this up for the first time? → [Deployment guide](#deployment-guide).**
It starts from an empty account and reaches a running lab in nine steps, with a
free checkpoint before anything is billed.

---

## Layout

```
├── versions.tf              provider + required OpenTofu version
├── backend.tf               S3-protocol backend, pointed at Vultr Object Storage
├── providers.tf             Vultr provider (API key comes from the environment)
├── variables.tf             the `defaults` baseline and `instances` schema
├── locals.tf                applies defaults inheritance and naming rules
├── data.tf                  OS and SSH-key name → ID lookups
├── main.tf                  the vultr_instance resource + preconditions
├── outputs.tf               IPs, SSH commands, DNS records, inventory
├── instances.auto.tfvars    ← the fleet lives here
├── templates/
│   └── cloud-init.yaml.tftpl    first-boot config (Docker, SSH hardening)
├── scripts/
│   ├── lib.sh                   shared Vultr API helpers
│   ├── bootstrap-backend.sh     one-time state bucket setup
│   ├── snapshot.sh              snapshot create/list/prune/delete
│   └── diagnose.sh              read-only health report
└── .github/
    ├── actions/tofu-init/       install OpenTofu + init the backend
    └── workflows/               the five workflows + one internal reusable plan
```

---

## Deployment guide

From nothing to a running lab. Around 20 minutes, most of it clicking through
the Vultr and GitHub web UIs.

**Out of the box this builds nothing** — `instances` in
[instances.auto.tfvars](instances.auto.tfvars) is empty, so an apply is a no-op
until you declare a machine in step 6.

Cost as you go — the whole setup and rehearsal is free apart from object
storage and a few cents of compute:

| | Cost |
|---|---|
| Steps 0–5 and 9 (setup, plan, diagnose) | free |
| Object Storage subscription (step 3) | ~$5/mo |
| `vc2-1c-2gb` smoke-test instance (step 6–8) | ~$0.015/hr |
| `vhp-4c-12gb-amd` real lab (step 9) | $0.099/hr, $72/mo cap |

Vultr bills compute hourly, so the full create → snapshot → destroy rehearsal
costs about ten cents.

---

### Step 0 — Local tools

`curl` and `jq` are required — the bootstrap script and the operational scripts
use them. `make` and `git` too.

```bash
curl --version && jq --version && make --version | head -1
```

**OpenTofu** is needed for `make check` / `make plan` locally. The workflows
install their own copy, so this is optional if you only ever drive the project
from the Actions tab — but you want it for step 0's validation. Match the
version CI uses (`1.12.5`, or whatever you set `TOFU_VERSION` to).

No sudo, user-local, checksum-verified:

Everything below runs inside `( … )` so it downloads in a scratch directory
without moving your shell out of the repo:

```bash
( set -euo pipefail
  V=1.12.5
  cd "$(mktemp -d)"
  curl -fsSL -O "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_linux_amd64.zip"
  curl -fsSL -O "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_SHA256SUMS"
  grep " tofu_${V}_linux_amd64.zip$" "tofu_${V}_SHA256SUMS" | sha256sum -c -
  unzip -o -q "tofu_${V}_linux_amd64.zip" tofu
  mkdir -p ~/.local/bin
  install -m 0755 tofu ~/.local/bin/tofu )

tofu version
```

If `tofu: command not found` persists, `~/.local/bin` is not on your `PATH` —
Ubuntu's `~/.profile` only adds it if the directory existed at login, so either
log out and back in or `export PATH="$HOME/.local/bin:$PATH"`.

For a system-wide managed install instead, use the
[official apt repository](https://opentofu.org/docs/intro/install/deb/) or
`snap install --classic opentofu`.

Then:

```bash
make check      # -> "Success! The configuration is valid."
```

`make check` needs no credentials and touches no remote state; it runs
`tofu init -backend=false` and validates. If it passes, the config is sound
before you spend anything. It leaves a gitignored `.terraform/` directory
behind — that is just the provider cache.

### Step 1 — Put the repo on GitHub

The workflows only exist once the repo is on GitHub.

```bash
git init && git add . && git commit -m "containerlabs: initial"
gh repo create <you>/containerlabs --private --source=. --push
```

Commit `.terraform.lock.hcl`. Do **not** commit `backend.hcl` — it is
gitignored, and step 3 generates it.

### Step 2 — Vultr API key and SSH key

**API key:** portal → **Account → API**. Enable it and add to the access
control list both your own IP and `0.0.0.0/0` — GitHub runner IPs are not
stable, so without the wildcard every workflow gets a 403. If that is too open
for you, run the workflows on a self-hosted runner with a fixed IP instead.

**SSH key:** portal → **Account → SSH Keys**, add your public key, and note its
**name**. You will need it in step 6. Keys are looked up by name, so a typo
fails at plan time rather than producing a machine you cannot log into.

### Step 3 — State backend in Vultr Object Storage

State cannot live on an ephemeral runner. Create an Object Storage subscription
in the portal (**Products → Objects**) — this is the first real cost, roughly
$5/mo — then:

```bash
export VULTR_API_KEY=...        # the only credential this needs
make bootstrap
```

It talks to `api.vultr.com` only: finds your subscription, creates the bucket
via Vultr's native `POST /v2/object-storage/{id}/bucket` with versioning
enabled, reads back the S3-protocol keys, and writes `backend.hcl`. No AWS CLI,
no AWS account. Re-running it is safe.

**Verify** — you should see `bucket '...' created` and `wrote .../backend.hcl`:

```bash
make objstore     # lists subscriptions and their buckets
cat backend.hcl   # bucket, region, endpoints.s3 — no credentials
```

Useful extras:

```bash
scripts/bootstrap-backend.sh --print-secrets                     # keys for step 4
scripts/bootstrap-backend.sh --subscription my-store --bucket x  # pick, if you have several
```

> **On the name `backend "s3"`.** OpenTofu ships no Vultr-specific backend.
> `s3` names a *protocol* — the client for any S3-compatible object store — and
> this project points it at `<cluster>.vultrobjects.com`. Nothing here creates
> or contacts an AWS resource.
>
> The one place AWS naming shows through is the credential pair
> `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. Those are the environment
> variables the underlying SDK reads; the values are your Vultr keys. OpenTofu
> [recommends against](https://opentofu.org/docs/language/settings/backends/s3/)
> putting keys in the backend config file, which is the only way to rename
> them, so they stay as environment variables fed from the
> `TFSTATE_ACCESS_KEY` / `TFSTATE_SECRET_KEY` secrets.

### Step 4 — Wire up GitHub

Repository → **Settings → Secrets and variables → Actions**.

Secrets:

| Name | Value |
|---|---|
| `VULTR_API_KEY` | Your Vultr API key |
| `TFSTATE_ACCESS_KEY` | Vultr Object Storage S3 access key |
| `TFSTATE_SECRET_KEY` | Vultr Object Storage S3 secret key |
| `CLOUDFLARE_API_TOKEN` | Optional. Enables automatic A/AAAA record sync; needs **Zone:Read + DNS:Edit** on the zone. |
| `IMG_ACCESS_KEY` | Optional*. Vultr Object Storage access key for the cEOS image bucket. |
| `IMG_SECRET_KEY` | Optional*. Vultr Object Storage secret key for the cEOS image bucket. |

The state keys come from `scripts/bootstrap-backend.sh --print-secrets`. The
Cloudflare token is created at **My Profile → API Tokens** with the *Edit zone
DNS* template plus `Zone → Zone → Read`, scoped to your zone; until it is set,
the apply workflow skips the DNS step and prints the records for you to
reconcile by hand.

Variables:

| Name | Example | Notes |
|---|---|---|
| `TFSTATE_BUCKET` | `containerlabs-tfstate` | |
| `TFSTATE_REGION` | `us-east-1` | Signing region only. Vultr ignores it; it does **not** need to match your cluster. |
| `TFSTATE_ENDPOINT` | `https://ewr1.vultrobjects.com` | Must match `endpoints.s3` in your generated `backend.hcl`. |
| `PROJECT` | `containerlabs` | Optional. Must match `project` in tfvars. |
| `TOFU_VERSION` | `1.12.5` | Optional. Defaults to 1.12.5. |
| `IMG_DIRECTORY` | `/opt/images` | Optional*. Directory cloud-init creates on docker-enabled instances, owned by the admin user. |
| `IMG_ENDPOINT` | `https://ewr1.vultrobjects.com` | Optional*. Object storage endpoint hosting the cEOS image. |
| `IMG_BUCKET` | `lab-images` | Optional*. Bucket holding the cEOS image. |
| `IMG_NAME` | `cEOS64-lab-4.32.2F.tar.xz` | Optional*. Object key; also the filename under `IMG_DIRECTORY`. |

\* The six `IMG_*` settings are all-or-nothing. Set every one and each
docker-enabled instance downloads the cEOS image into `IMG_DIRECTORY` on first
boot and imports it into Docker as `ceos:latest`; set none and the download is
skipped; a partial set fails the plan. The credentials are baked into the
instance's cloud-init user data, so treat user data (and saved plans) as
sensitive once these are configured.

Or from the CLI:

```bash
gh secret set VULTR_API_KEY
gh secret set TFSTATE_ACCESS_KEY
gh secret set TFSTATE_SECRET_KEY
gh secret set CLOUDFLARE_API_TOKEN   # optional: automatic A/AAAA record sync
gh variable set TFSTATE_BUCKET   --body containerlabs-tfstate
gh variable set TFSTATE_REGION   --body us-east-1
gh variable set TFSTATE_ENDPOINT --body https://ewr1.vultrobjects.com

# Optional, all-or-nothing: cEOS image download on docker-enabled instances.
gh secret set IMG_ACCESS_KEY
gh secret set IMG_SECRET_KEY
gh variable set IMG_DIRECTORY --body /opt/images
gh variable set IMG_ENDPOINT  --body https://ewr1.vultrobjects.com
gh variable set IMG_BUCKET    --body lab-images
gh variable set IMG_NAME      --body cEOS64-lab-4.32.2F.tar.xz
```

### Step 5 — Environments (the approval gate)

**Settings → Environments**, create two:

- `containerlabs` — used by **2 · Apply**
- `containerlabs-destroy` — used by **3 · Destroy**

Add **required reviewers** to each. This is what turns these workflows into
reviewed operations. Because plan and apply are separate jobs, the approver
sees a plan that has *already been generated* — and OpenTofu refuses to apply
it if state moved in the meantime.

> Required reviewers on private repos need GitHub Pro/Team. On a free private
> repo the environments still work, just without the gate — the typed
> confirmation on Destroy still applies.

### Step 6 — Free smoke test, before spending anything

Run **5 · Diagnose** from the Actions tab with `check_drift: true`.

This creates nothing, and with an empty fleet it still exercises the two
riskiest unknowns end to end: it authenticates to the Vultr API, and its drift
job runs `tofu init` + `tofu plan` against your new bucket — proving the Object
Storage backend handshake.

**Expected:** green run. The summary shows your account balance, "No instances
are currently tagged for project `containerlabs`", and "No drift."

If this fails, fix it here — it is free. See [Troubleshooting](#troubleshooting).

### Step 7 — Declare one cheap instance

Do the first real deploy on a small plan; switch to the baseline once the
mechanics are proven. In [instances.auto.tfvars](instances.auto.tfvars):

```hcl
ssh_key_names = ["your-key-name"]     # required — see below

instances = {
  lab01 = {
    plan   = "vc2-1c-2gb"             # ~$0.015/hr instead of $0.099/hr
    region = "lax"
  }
}
```

`ssh_key_names` is not optional. cloud-init sets `PasswordAuthentication no` on
first boot, so an instance with no key is reachable only through the Vultr web
console. The plan will refuse rather than build one.

Open a PR. **1 · Plan** runs automatically and posts the plan as a comment —
read it, confirm it is `1 to add, 0 to change, 0 to destroy`, then merge.

### Step 8 — The full rehearsal

Run all four remaining workflows in order. Together they cost a few cents.

1. **2 · Apply** — `instance: all`. Approve at the environment gate. The
   summary prints the IP and an SSH command.
2. Wait ~3 minutes for cloud-init, then check it landed:
   ```bash
   ssh root@<ip> 'cat /etc/containerlabs/metadata.json; ls /etc/containerlabs/ready; docker version'
   ```
   The `ready` marker is written last, so its presence means cloud-init finished.
3. **4 · Snapshot** — `action: create`, `instance: lab01`, `wait: true`. Then
   `action: list` to see it.
4. **5 · Diagnose** — now with a real instance. Expect port 22 open and the
   fleet table populated.
5. **3 · Destroy** — `instance: lab01`, `confirm: destroy lab01`,
   `snapshot_first: true`. Stops the billing.

If all five pass, the system works.

### Step 9 — Switch to the real baseline

Drop the `plan`/`region` overrides so `lab01` inherits `var.defaults`
(`vhp-4c-12gb-amd` in `lax`), or set them to whatever you actually want:

```hcl
instances = {
  lab01 = {}
}
```

PR → read the plan → merge → **2 · Apply**.

Note that this **replaces** the instance rather than resizing it if the disk
shrinks; the plan tells you which. With the `CLOUDFLARE_API_TOKEN` secret set,
the apply workflow creates or updates the `lab01.dhs-labs.us` A and AAAA
records automatically (`scripts/dns-sync.sh`), and the destroy workflow
removes them; without it, the `dns_records` output lists what the fleet
expects so you can reconcile by hand.

---

## Defining the fleet

Every instance inherits a single baseline, modelled on the existing
`containerlabs.dhs-labs.us` box:

| `defaults` field | Value | |
|---|---|---|
| `plan` | `vhp-4c-12gb-amd` | 4 vCPU, 12 GB, 260 GB AMD NVMe, 7 TB transfer, $72/mo |
| `region` | `lax` | Los Angeles |
| `os_name` | `Ubuntu 26.04 LTS x64` | os_id 2760 |
| `user_scheme` | `root` | |
| `docker` | `true` | Docker CE + compose, log rotation |
| `enable_ipv6` | `true` | |
| `backups` | `false` | Vultr automatic backups, billed separately |

So a whole lab is one line, and you override only what differs:

```hcl
project  = "containerlabs"
dns_zone = "dhs-labs.us"

ssh_key_names = ["ahopkins-yubikey"]

instances = {
  lab01 = {}                                    # the full baseline

  lab02 = {                                     # bigger, with extras
    plan           = "vhp-8c-24gb-amd"
    extra_packages = ["tmux", "build-essential"]
  }

  lab03 = {                                     # different region and image
    region  = "ewr"
    os_name = "Ubuntu 24.04 LTS x64"
    backups = true
    backup_schedule = { type = "daily", hour = 4 }
  }
}
```

Change the baseline itself in the `defaults` block — but note that changing a
default re-plans every instance that has not overridden it. `plan` and `region`
changes are resizes/moves where Vultr allows them; changing `os_name` rebuilds.

**Naming.** With `dns_zone` set, hostname and label default to
`<key>.<dns_zone>` — `lab01.dhs-labs.us`. Set `dns_zone = ""` to get
`<project>-<key>` instead. The HCL itself creates no DNS records;
`scripts/dns-sync.sh` reconciles the `dns_records` output (A and AAAA)
against Cloudflare — automatically after each workflow apply and destroy
(once the `CLOUDFLARE_API_TOKEN` secret is set), or on demand with `make dns`
(`DRY_RUN=1` to preview). Records it creates carry a
`managed-by:opentofu:<project>` comment, and its `--prune` only ever deletes
records carrying that comment, so hand-made records in the zone are never
touched.

The map key (`lab01`) is the handle every workflow's `instance` input takes.
**Renaming a key destroys and recreates the machine** — to rename without
rebuilding, set `label` and `hostname` instead.

Discover valid values:

```bash
make regions              # lax, ewr, ams, ...
make plans                # plans available in lax, with prices
make plans REGION=ewr     # ... or elsewhere
make os                   # exact os_name strings
```

**Tags are load-bearing.** Every instance is stamped with `containerlabs`,
`managed-by:opentofu`, and `instance:<key>`. The first two are the ownership
marker — the snapshot and diagnose scripts ignore anything without them, so
instances you create by hand in the portal are never touched. The third is how
those scripts map a machine back to its tfvars key, which is why they keep
working when you override `label` to something arbitrary.

Full option list with defaults and validation rules:
[variables.tf](variables.tf).

> Editing `templates/cloud-init.yaml.tftpl` only affects **new** instances.
> cloud-init runs once, on first boot.

---

## The workflows

### 1 · Plan

Runs automatically on PRs that touch `.tf`, `.tfvars`, or `templates/`, and
posts a rolling comment with the plan. Also runnable by hand with an optional
`instance` target.

### 2 · Apply

Inputs: `instance` (default `all`), `snapshot_first`, `refresh`.

Two jobs — plan, then apply the saved plan behind the environment gate. Skips
the apply entirely when the plan is empty. With `snapshot_first`, a snapshot is
taken **and waited on** before anything changes.

### 3 · Destroy

Inputs: `instance` (required), `confirm` (required), `snapshot_first`
(default **on**).

You must type the confirmation phrase exactly:

```
instance: lab01          confirm: destroy lab01
instance: all            confirm: destroy all
```

Then the `containerlabs-destroy` environment gate, then a pre-destroy snapshot
that the workflow waits for — a snapshot still uploading when the disk is
deleted is not a backup.

### 4 · Snapshot

Actions: `list`, `create`, `prune`, `delete`.

Does not open OpenTofu state at all, so it runs happily while a plan or apply
is in flight — which is the point. You can snapshot before a risky change, or
recover an image when state is broken.

`prune` keeps the N newest per instance and, with `older_than`, only deletes
beyond that age. It **defaults to `dry_run: true`** — untick it to actually
delete. Snapshots whose ID appears in any `.tfvars` file are never deleted,
because they are live restore targets.

### 5 · Diagnose

Inputs: `instance`, `ports`, `max_snapshot_age`, `check_drift`,
`fail_on_problem`.

Produces a job-summary report covering account balance, per-instance
subscription/power/server status, TCP reachability, snapshot coverage and age,
and instances in the account that this stack does *not* manage. Exits non-zero
on findings so the run goes red without anyone reading the log.

`check_drift` additionally runs `tofu plan -detailed-exitcode` to answer "does
reality still match the config?" — this is the only part that takes the state
lock.

---

## Snapshots and restore

Snapshots are **not** OpenTofu resources. Taking one is an event, not a piece
of desired state: as resources, every snapshot you ever took would stay in
state forever and taking a new one would be a config edit. So the workflow
calls the Vultr API directly, and snapshots outlive the stack.

Restores, on the other hand, *are* declarative:

1. **4 · Snapshot** with `action: list` → copy the snapshot UUID.
2. Set it on an instance:

   ```hcl
   lab01 = {
     plan        = "vc2-2c-4gb"
     region      = "ewr"
     snapshot_id = "b1e2…"
   }
   ```

3. **2 · Apply**. `snapshot_id` takes precedence over `os_name`.

Descriptions follow `<project>/<instance>/<UTC timestamp>`, which is what
`list` and `prune` key off.

---

## Local use

```bash
make help        # list targets
make check       # fmt -check + validate, no credentials or network state needed
make init        # tofu init against the remote backend (needs backend.hcl)
make plan
make apply
make diagnose    # needs VULTR_API_KEY
make snapshots
```

`make check` works with no credentials. Everything else needs
`VULTR_API_KEY`, plus `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` set to your
Object Storage keys for anything that reads state.

---

## Design notes

**Why the map-of-instances shape.** One workspace, one state file, `for_each`
over a map. Adding a lab is a two-line tfvars diff reviewable in a PR, and the
map key doubles as the `-target` address for single-instance operations.

**Targeting.** Passing an `instance` other than `all` adds
`-target=vultr_instance.this["key"]`. OpenTofu prints a warning about this and
so does the workflow: a targeted plan cannot see drift anywhere else. Use it
for surgery, use `all` for routine work.

**Locking.** Vultr Object Storage has no DynamoDB equivalent, so state locking
uses `use_lockfile` (a lock object in the same bucket, via S3 conditional
writes). Not every S3-compatible provider implements those, so the workflows
*also* share a GitHub Actions `concurrency` group —
`containerlabs-tofu-state` — which serialises Plan, Apply, Destroy and the
drift check regardless. Snapshot runs in its own group since it never opens
state.

**The `skip_*` flags in [backend.tf](backend.tf)** each disable an AWS-only
preflight call (STS credential validation, EC2 metadata lookup, account-ID
resolution) that would otherwise fire against a service that does not exist
here and fail. `skip_s3_checksum` is required too: Vultr rejects the
trailing-checksum upload format the current SDK defaults to. `use_path_style`
matches Vultr's `host/bucket/key` addressing.

**Secrets.** The Vultr API key is never written to tfvars or HCL — the provider
reads `VULTR_API_KEY` from the environment. Vultr-generated instance passwords
land in state (unavoidable) and are exposed only through the `sensitive`
`default_passwords` output.

---

## Troubleshooting

**`tofu init` fails acquiring a state lock, or complains about conditional
writes.** Your Object Storage cluster does not implement S3 conditional writes.
Remove `use_lockfile = true` from [backend.tf](backend.tf); the
`containerlabs-tofu-state` concurrency group still serialises every run.

**`init` fails with a signature, checksum, or 400 error.** Check
`TFSTATE_ENDPOINT` exactly matches `endpoints.s3` in your generated
`backend.hcl` — scheme included, no trailing slash, and no bucket name in the
host. `skip_s3_checksum` must stay `true`: Vultr rejects the SDK's default
trailing-checksum uploads.

**Workflows get `403` from the Vultr API but it works from your laptop.** The
API key's access control list. Runner IPs are not stable — add `0.0.0.0/0`
(step 2) or move to a self-hosted runner with a fixed IP.

**Plan fails: no SSH key or OS matches.** Both are looked up by exact name.
Compare against `make os` and the portal's **Account → SSH Keys**.

**Apply fails with a tag error.** If Vultr rejects the colon in
`managed-by:opentofu` or `instance:<key>`, change the three tag strings in
[locals.tf](locals.tf) and the matching `startswith("instance:")`,
`index("instance:" + $n)`, and `index("managed-by:opentofu")` filters in
[scripts/lib.sh](scripts/lib.sh) and [scripts/diagnose.sh](scripts/diagnose.sh)
— e.g. to `managed-by-opentofu` and `instance-<key>`.

**Apply succeeded but SSH is refused.** cloud-init is almost certainly still
installing Docker. `/etc/containerlabs/ready` is written last. Check progress
from the Vultr web console with `cloud-init status --wait`, or read
`/var/log/cloud-init-output.log`.

**Diagnose reports port 22 closed but you can SSH fine.** The probe runs from a
GitHub runner. If you attached a `firewall_group_id` that only allows your own
IP, closed is the correct answer — the report says as much inline.

**Apply reports the saved plan is stale.** State moved between the plan job and
the approval. That is the safety property working; just re-run **2 · Apply**.

**Destroy says "Nothing to destroy".** The target is not in state. If the
machine exists in Vultr regardless, it was created outside this stack —
**5 · Diagnose** lists those under "Unmanaged instances".

---

## Verified, and not

Built and checked against OpenTofu 1.12.5 and vultr/vultr 2.32.0 (resolved from
the `~> 2.26` constraint):

- `tofu fmt -check` and `tofu validate` pass.
- `plan = vhp-4c-12gb-amd` exists, is available in `lax`, and is 4 vCPU /
  12288 MB / 260 GB AMD NVMe at $72/mo. `Ubuntu 26.04 LTS x64` exists as
  os_id 2760. Both checked against the live public Vultr catalogue.
- The `defaults` inheritance was executed: a bare `lab01 = {}` resolves to the
  full baseline, per-instance overrides win (including a deliberate `false`
  beating a `true` default), snapshot-restored instances are excluded from OS
  lookups, and OS/SSH-key lookups deduplicate.
- All three `lifecycle` preconditions were shown to fire on the inputs that
  should trip them, and not on valid ones.
- The cloud-init template was rendered and parsed as YAML across the
  Docker-on/off and `extra_cloud_init` combinations.
- Ubuntu 26.04 is *Resolute Raccoon*, and Docker's apt repo publishes a
  populated `resolute` suite — `docker-ce`, `docker-ce-cli`, `containerd.io`,
  `docker-buildx-plugin` and `docker-compose-plugin` are all present
  (`docker-ce 5:29.3.1-1~ubuntu.26.04~resolute`), and the signing key returns
  200. So the repo line the template writes resolves on this image.
- `snapshot.sh` and `diagnose.sh` were exercised end-to-end against a mock
  Vultr API covering cursor pagination, instance resolution by key / DNS label
  / UUID, prune ranking and age filtering, the tfvars-pinning guard, and the
  `--yes` guards.

Not verified, because it needs a live account with billing:

- An actual `tofu apply` creating a real instance.
- That Vultr accepts a colon in tag values. It is undocumented, but govultr's
  own examples use tags containing spaces, so tags look permissive. If it is
  rejected, the first apply fails loudly and the fix is to change the three tag
  strings in [locals.tf](locals.tf) and the matching `startswith`/`index`
  filters in [scripts/lib.sh](scripts/lib.sh).
- The Vultr Object Storage S3 backend handshake, including whether
  `use_lockfile` conditional writes are supported on your cluster. If `init`
  rejects the lock, drop `use_lockfile` from [backend.tf](backend.tf) — the
  Actions concurrency group still serialises runs.
- Whether cloud-init actually completes on Vultr's Ubuntu 26.04 image. The
  package repo is confirmed present (above), but the run itself is untested.

`.terraform.lock.hcl` is committed and currently holds `linux_amd64` hashes
only, which is what the runners use. If you also run OpenTofu from macOS, add
those hashes once:

```bash
tofu providers lock -platform=darwin_arm64 -platform=linux_amd64
```

Step 6 of the deployment guide exists to close the first three of these for
free, before any compute is billed.
