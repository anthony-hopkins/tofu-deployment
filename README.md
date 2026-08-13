# crackbox

OpenTofu-managed Vultr compute instances for running **hashcat against large
dictionaries** in a home lab, driven entirely from manually-triggered GitHub
Actions workflows.

A box comes up with hashcat and a working OpenCL runtime, its bulk storage
formatted and mounted at `/data`, and two public corpora already pulled down —
rockyou in the admin user's home, SecLists on the data mount. Rent it by the
hour, crack, snapshot, destroy.

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
It starts from an empty account and reaches a running box in nine steps, with a
free checkpoint before anything is billed.

> **This box is expensive to leave running.** The default plan is $1.223/hr —
> about $893 a month if you forget it. The intended shape is: apply, crack,
> snapshot if the potfile matters, destroy. **3 · Destroy** is what stops the
> billing; powering the instance off does not.

> **Coming from the `containerlabs` revision of this stack?** The backend state
> key moved from `containerlabs/terraform.tfstate` to
> `crackbox/terraform.tfstate` ([backend.tf](backend.tf)). That is deliberate,
> and it is the non-destructive choice: applying this config starts from an
> empty state and builds crackboxes, rather than reading the old state and
> proposing to destroy your labs. The flip side is that **any instance from the
> old stack keeps running and keeps billing, now unmanaged.** Destroy it from
> the previous revision first, or clean it up in the portal. **5 · Diagnose**
> will list it under "Unmanaged instances".

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
│   └── cloud-init.yaml.tftpl    first-boot config (hashcat, /data, SSH hardening)
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

From nothing to a running box. Around 20 minutes, most of it clicking through
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
| `vx1-g-32c-128g-1920s` real crackbox (step 9) | **$1.223/hr, $892.79/mo** |

Vultr bills compute hourly, so the full create → snapshot → destroy rehearsal
costs about ten cents — the rehearsal deliberately runs on the cheap plan, and
you only reach the real one in step 9.

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
git init && git add . && git commit -m "crackbox: initial"
gh repo create <you>/crackbox --private --source=. --push
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

The state keys come from `scripts/bootstrap-backend.sh --print-secrets`. The
Cloudflare token is created at **My Profile → API Tokens** with the *Edit zone
DNS* template plus `Zone → Zone → Read`, scoped to your zone; until it is set,
the apply workflow skips the DNS step and prints the records for you to
reconcile by hand.

Variables:

| Name | Example | Notes |
|---|---|---|
| `TFSTATE_BUCKET` | `crackbox-tfstate` | |
| `TFSTATE_REGION` | `us-east-1` | Signing region only. Vultr ignores it; it does **not** need to match your cluster. |
| `TFSTATE_ENDPOINT` | `https://ewr1.vultrobjects.com` | Must match `endpoints.s3` in your generated `backend.hcl`. |
| `PROJECT` | `crackbox` | Optional. Must match `project` in tfvars. |
| `TOFU_VERSION` | `1.12.5` | Optional. Defaults to 1.12.5. |

Dictionaries are not configured here — you upload them yourself once the box
is up. See [Getting dictionaries onto the
box](#getting-dictionaries-onto-the-box).

Or from the CLI:

```bash
gh secret set VULTR_API_KEY
gh secret set TFSTATE_ACCESS_KEY
gh secret set TFSTATE_SECRET_KEY
gh secret set CLOUDFLARE_API_TOKEN   # optional: automatic A/AAAA record sync
gh variable set TFSTATE_BUCKET   --body crackbox-tfstate
gh variable set TFSTATE_REGION   --body us-east-1
gh variable set TFSTATE_ENDPOINT --body https://ewr1.vultrobjects.com
```

### Step 5 — Environments (the approval gate)

**Settings → Environments**, create two:

- `crackbox` — used by **2 · Apply**
- `crackbox-destroy` — used by **3 · Destroy**

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
are currently tagged for project `crackbox`", and "No drift."

If this fails, fix it here — it is free. See [Troubleshooting](#troubleshooting).

### Step 7 — Declare one cheap instance

Do the first real deploy on a small plan; switch to the baseline once the
mechanics are proven. In [instances.auto.tfvars](instances.auto.tfvars):

```hcl
ssh_key_names = ["your-key-name"]     # required — see below

instances = {
  crack01 = {
    plan   = "vc2-1c-2gb"             # ~$0.015/hr instead of $1.223/hr
    region = "sea"
    hashcat = false                   # skip the toolchain on a 1 GB test box
  }
}
```

`hashcat = false` here on purpose: this step is proving the *deployment
machinery*, and installing hashcat plus an OpenCL runtime on a 1 vCPU box
proves nothing you need yet.

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
   ssh ahopkins@<ip> 'cat /etc/crackbox/metadata.json; ls /etc/crackbox/ready'
   ```
   The `ready` marker is written last, so its presence means cloud-init finished.
3. **4 · Snapshot** — `action: create`, `instance: crack01`, `wait: true`. Then
   `action: list` to see it.
4. **5 · Diagnose** — now with a real instance. Expect port 22 open and the
   fleet table populated.
5. **3 · Destroy** — `instance: crack01`, `confirm: destroy crack01`,
   `snapshot_first: true`. Stops the billing.

If all five pass, the system works.

### Step 9 — Switch to the real baseline

Drop the overrides so `crack01` inherits `var.defaults`
(`vx1-g-32c-128g-1920s` in `sea`), or set them to whatever you actually want:

```hcl
instances = {
  crack01 = {}
}
```

PR → read the plan → merge → **2 · Apply**. This is the point at which the
meter starts at $1.223/hr.

Once cloud-init finishes, confirm the two things that matter:

```bash
ssh ahopkins@<ip> 'cat /etc/crackbox/backends.txt; df -h /data; ls -la /data/wordlists'
```

`backends.txt` is `hashcat -I` captured on first boot — it should list a pocl
device with 32 compute units. `df -h /data` should show the 1920 GB filesystem,
not the root disk.

Note that switching plans **replaces** the instance rather than resizing it if
the disk shrinks; the plan tells you which. With the `CLOUDFLARE_API_TOKEN` secret set,
the apply workflow creates or updates the `crack01.dhs-labs.us` A and AAAA
records automatically (`scripts/dns-sync.sh`), and the destroy workflow
removes them; without it, the `dns_records` output lists what the fleet
expects so you can reconcile by hand.

---

## Defining the fleet

Every instance inherits a single baseline:

| `defaults` field | Value | |
|---|---|---|
| `plan` | `vx1-g-32c-128g-1920s` | 32 vCPU, 128 GB, 1920 GB, AMD, 9 TB transfer, $892.79/mo |
| `region` | `sea` | Seattle |
| `os_name` | `Ubuntu 26.04 LTS x64` | os_id 2760 |
| `user_scheme` | `root` | |
| `hashcat` | `true` | hashcat + pocl OpenCL, `/data` found and mounted |
| `enable_ipv6` | `true` | |
| `backups` | `false` | Vultr automatic backups, billed separately |

### About that plan

Two things about `vx1-g-32c-128g-1920s` are worth knowing before you change it.

**It has no GPU.** The `-g-` is *general purpose* — the other half of the `vx1`
family is `-m-`, memory-optimized — and the plans API reports `gpu_brand:
"none"`. Cracking runs on 32 AMD threads through **pocl**, the portable CPU
OpenCL runtime, which is what the `pocl-opencl-icd` package in the cloud-init
payload is for. That is an order of magnitude off a mid-range GPU on fast
hashes (MD5, NTLM, SHA-1) and much closer on the deliberately slow ones
(bcrypt, scrypt, argon2), where GPUs lose most of their advantage anyway.

If the trade stops making sense, the `vcg-*` plans carry NVIDIA cards —
`vcg-a40-6c-30g-12vram` is an A40 with 12 GB VRAM and 550 GB of disk at
$315/mo, less than half the price of this one. Switching is not just a plan
string: the cloud-init payload would need an NVIDIA driver + CUDA install
added, since hashcat needs the vendor runtime to see the card.

**The `-1920s` suffix is what buys the disk.** The bare `vx1-g-32c-128g` is
$700.80/mo but ships a **1 GB** boot disk and expects block storage to be
attached separately — nowhere to put a dictionary corpus. The suffixed variant
is $892.79/mo with 1920 GB.

Region is `sea` because this plan is not offered in `lax`. It is available in
`ewr`, `ord`, `sea`, `atl`, `ams` and `nrt`.

### Storage layout

`hashcat = true` instances get their bulk storage found, formatted and mounted
on first boot. The storage on a `vx1-*-<n>s` plan arrives as its own device
rather than as extra room on the root disk, so `mount-data.sh` picks the
largest disk that is not the root disk and carries *nothing at all* — no
filesystem, no partition table, no mount anywhere in its tree — formats it
ext4 and adds it to `/etc/fstab` by UUID with `nofail`. A device that already
holds data is left alone, which is what makes the script safe to re-run and
safe when you attach your own block volume.

If there is no such device the mount is skipped and the directories are simply
created on the root filesystem, so the payload also works on plans that put
everything on one disk.

```
/data                 the mount point (var.data_mount)
├── wordlists/        dictionaries you upload
├── seclists/         SecLists clone, /usr/share/seclists -> here
├── hashes/           target hashes
├── rules/            rule files
└── sessions/         --session restore points
```

The four created directories are owned by `var.admin_user`, so runs, potfiles
and session restores need no sudo. `rockyou.txt` lands in the admin user's home
rather than here — at 133 MB it is small enough not to need the bulk disk.

### Declaring instances

A whole box is one line, and you override only what differs:

```hcl
project  = "crackbox"
dns_zone = "dhs-labs.us"

ssh_key_names = ["ahopkins-yubikey"]

instances = {
  crack01 = {}                                    # the full baseline

  crack02 = {                                     # bigger, with extras
    plan           = "vx1-g-64c-256g-3840s"
    extra_packages = ["hashcat-data", "john"]
  }

  jumpbox = {                                     # no cracking toolchain at all
    plan    = "vc2-1c-2gb"
    hashcat = false
    backups = true
    backup_schedule = { type = "daily", hour = 4 }
  }
}
```

Change the baseline itself in the `defaults` block — but note that changing a
default re-plans every instance that has not overridden it. `plan` and `region`
changes are resizes/moves where Vultr allows them; changing `os_name` rebuilds.

**Naming.** With `dns_zone` set, hostname and label default to
`<key>.<dns_zone>` — `crack01.dhs-labs.us`. Set `dns_zone = ""` to get
`<project>-<key>` instead. The HCL itself creates no DNS records;
`scripts/dns-sync.sh` reconciles the `dns_records` output (A and AAAA)
against Cloudflare — automatically after each workflow apply and destroy
(once the `CLOUDFLARE_API_TOKEN` secret is set), or on demand with `make dns`
(`DRY_RUN=1` to preview). Records it creates carry a
`managed-by:opentofu:<project>` comment, and its `--prune` only ever deletes
records carrying that comment, so hand-made records in the zone are never
touched.

The map key (`crack01`) is the handle every workflow's `instance` input takes.
**Renaming a key destroys and recreates the machine** — to rename without
rebuilding, set `label` and `hostname` instead.

Discover valid values:

```bash
make regions              # sea, ewr, ams, ...
make plans                # plans available in sea, with prices
make plans REGION=ewr     # ... or elsewhere
make os                   # exact os_name strings
```

**Tags are load-bearing.** Every instance is stamped with `crackbox`,
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

## Running hashcat

What the payload installs: `hashcat`, `pocl-opencl-icd` and
`ocl-icd-libopencl1` (the OpenCL runtime and loader — hashcat will not start
without one), `clinfo`, `hcxtools` (the `hcxpcapngtool` front end to hashcat's
22000/22001 WPA modes), `tmux`, and the corpus-handling tools `7zip`, `pigz`,
`xz-utils`, `zstd` and `rsync`.

It also fetches two corpora on first boot:

| What | Where | Size |
|---|---|---|
| rockyou | `~/rockyou.txt` | 53 MB down, 133 MB extracted |
| SecLists | `/data/seclists`, symlinked from `/usr/share/seclists` | ~1 GB, `--depth 1` clone |

Both are plain anonymous downloads — no credentials, nothing sensitive in user
data — and both are controlled by a variable you can set to `""` to skip
(`rockyou_url`, `seclists_repo` in [variables.tf](variables.tf)).

> **`seclists` is not an Ubuntu package.** `apt install seclists` is a Kali
> instruction; the name is in no Ubuntu suite at all, so that command fails
> here. This stack clones it from
> [upstream](https://github.com/danielmiessler/SecLists) instead, onto the data
> mount because it is over a gigabyte, and symlinks `/usr/share/seclists` at it
> so anything expecting Kali's path still resolves.

First, confirm the backend came up. Cloud-init captures `hashcat -I` on first
boot, precisely so a box whose OpenCL runtime failed still finishes booting and
leaves you something to read:

```bash
cat /etc/crackbox/backends.txt
clinfo -l
```

You want a pocl device reporting 32 compute units. If hashcat declines to use
it — pocl is not a vendor runtime, and hashcat is conservative about those —
`--force` is the documented escape hatch, and `-D 1` restricts it to CPU
devices explicitly.

### Getting dictionaries onto the box

rockyou and SecLists arrive on their own (see above). `/data/wordlists` is
created owned by the admin user and left empty for everything else — how your
private corpus gets there is up to you.

`rsync` over SSH is the usual answer, and the one worth using for anything
large — it resumes, so a dropped connection halfway through a 100 GB
dictionary costs you nothing:

```bash
rsync -avP --partial ./wordlists/ ahopkins@<ip>:/data/wordlists/
rsync -avP --partial ./rules/     ahopkins@<ip>:/data/rules/
```

`-P` is `--partial --progress`; re-running the same command picks up where it
stopped. If you keep your corpus in object storage, pulling it *from* the box
is faster than pushing from home — `curl`, `rclone` or `s5cmd` on the box
itself, straight into `/data/wordlists`.

**Leave dictionaries compressed.** hashcat reads gzip wordlists natively, so
`rockyou.txt.gz` works as an argument exactly like `rockyou.txt` would, and
decompressing a hundred-gigabyte corpus costs disk and buys nothing. `7zip`,
`pigz`, `xz-utils` and `zstd` are installed if you do need to repack something.

Keep it all under `/data` — that is the 1920 GB volume. The root filesystem is
small.

### Running a job

Then, **inside tmux**, because these runs outlive the SSH session:

```bash
tmux new -s crack

# Straight dictionary run. hashcat reads the .gz without unpacking it.
hashcat -m 1000 -a 0 -w 3 \
  --session ntlm --potfile-path /data/sessions/ntlm.pot \
  /data/hashes/ntlm.txt /data/wordlists/rockyou.txt.gz

# Dictionary + rules — where a large corpus actually earns the 32 threads.
hashcat -m 1000 -a 0 -w 3 \
  --session ntlm-r --potfile-path /data/sessions/ntlm-r.pot \
  -r /data/rules/best64.rule \
  /data/hashes/ntlm.txt /data/wordlists/weakpass_4.txt.gz
```

`-w 3` is the "high" workload profile; `-w 4` ("nightmare") is fine here since
nothing else uses the box. Detach with `Ctrl-b d`, reattach with
`tmux attach -t crack`.

Resume an interrupted run with `--session <name> --restore`. Keep sessions and
potfiles under `/data` as above — the root filesystem is small and, more to the
point, `/data` is the thing worth snapshotting.

**Cracked passwords live in the potfile.** Before you destroy the instance,
either copy it off:

```bash
rsync -avz ahopkins@<ip>:/data/sessions/ ./sessions/
```

…or run **3 · Destroy** with `snapshot_first: true` and restore from the
snapshot later (see [Snapshots and restore](#snapshots-and-restore)).

> Snapshots capture the boot disk. Whether a Vultr snapshot of a `vx1-*-<n>s`
> instance also captures the separately-mounted 1920 GB volume is **not
> verified here** — see [Verified, and not](#verified-and-not). Copy the
> potfile off explicitly if it matters.

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
instance: crack01          confirm: destroy crack01
instance: all            confirm: destroy all
```

Then the `crackbox-destroy` environment gate, then a pre-destroy snapshot
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
   crack01 = {
     plan        = "vc2-2c-4gb"
     region      = "ewr"
     snapshot_id = "b1e2…"
   }
   ```

3. **2 · Apply**. `snapshot_id` takes precedence over `os_name`.

Descriptions follow `<project>/<instance>/<UTC timestamp>`, which is what
`list` and `prune` key off.

### Snapshots versus automatic backups

`backups` is `false` in the baseline, deliberately. Vultr automatic backups are
a percentage surcharge on the instance price billed continuously, and they
buy scheduled images of a box that is meant to exist for the length of one
cracking run. Snapshots do the same job on demand, and **3 · Destroy** already
defaults `snapshot_first` to on, so the routine teardown captures the disk
without you having to remember.

> **Snapshots outlive the instance, and keep billing.** This is the part that
> catches people out: destroying the box stops the hourly compute charge, but
> every snapshot you left behind is still stored and still charged, and a
> snapshot of a box whose data disk is full of dictionaries is not small.
> "I destroyed it, so I am not paying" is only true once the snapshots are
> pruned too.

So the cost discipline is two-sided — destroy the box *and* keep the snapshot
count down:

```bash
make snapshots                 # what exists right now
make prune                     # dry run, keeps the 3 newest per instance
make prune KEEP=1              # dry run, keeps only the newest
bash scripts/snapshot.sh prune --keep 1 --yes    # actually delete
```

`prune` defaults to a dry run and never deletes a snapshot whose ID appears in
a `.tfvars` file, since that is a live restore target. Workflow **4 · Snapshot**
exposes the same thing with an `older_than` filter.

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
over a map. Adding a box is a two-line tfvars diff reviewable in a PR, and the
map key doubles as the `-target` address for single-instance operations.

**Why the dictionary corpus is outside the stack.** It is bytes on a disk, not
desired state. Modelling it here would put object keys — and their sizes — into
state, make re-uploading a dictionary a config edit, and put a multi-hour
transfer inside cloud-init where nothing can resume it. Uploading over `rsync`
after the box is up is resumable, interruptible, and needs no credentials baked
into user data.

**Why `/data` is discovered rather than declared.** The template does not name
`/dev/vdb`. Device names are not stable across a rebuild, the `vx1` plans and
an attached `vultr_block_storage` volume present their storage differently, and
a plan whose storage is all on the root disk presents none at all. Probing for
"the largest disk carrying nothing" handles all three, and refusing to touch a
disk that already has a filesystem is what makes it safe to re-run and safe
around volumes you attached yourself.

**Targeting.** Passing an `instance` other than `all` adds
`-target=vultr_instance.this["key"]`. OpenTofu prints a warning about this and
so does the workflow: a targeted plan cannot see drift anywhere else. Use it
for surgery, use `all` for routine work.

**Locking.** Vultr Object Storage has no DynamoDB equivalent, so state locking
uses `use_lockfile` (a lock object in the same bucket, via S3 conditional
writes). Not every S3-compatible provider implements those, so the workflows
*also* share a GitHub Actions `concurrency` group —
`crackbox-tofu-state` — which serialises Plan, Apply, Destroy and the
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
`crackbox-tofu-state` concurrency group still serialises every run.

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
running its package upgrade, or the box is rebooting after one.
`/etc/crackbox/ready` is written last. Check progress from the Vultr web
console with `cloud-init status --wait`, or read
`/var/log/cloud-init-output.log`.

**`df -h /data` shows the root filesystem, not the big disk.** `mount-data.sh`
only claims a disk that is completely empty — no filesystem, no partition
table, no mount. Run `lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT` to see what it
saw. A device that already carries a filesystem is deliberately left alone;
mount it yourself, or wipe it and re-run
`sudo bash /opt/crackbox/mount-data.sh` (kept on the box for exactly this).

**hashcat exits with "No devices found/left".** The OpenCL runtime did not come
up. `clinfo -l` should list a pocl platform; if it lists nothing, check that
`pocl-opencl-icd` actually installed (`dpkg -l pocl-opencl-icd`) — a failed
`package_upgrade` earlier in cloud-init can take the package install down with
it. `/etc/crackbox/backends.txt` holds what `hashcat -I` said on first boot.

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
the `~> 2.32` constraint):

- `tofu fmt -check` and `tofu validate` pass.
- `plan = vx1-g-32c-128g-1920s` exists and is 32 vCPU / 131072 MB / 1920 GB /
  AMD at $892.79/mo ($1.223/hr), available in `ewr`, `ord`, `sea`, `atl`, `ams`
  and `nrt` — **not** in `lax`, which is why the default region moved. The bare
  `vx1-g-32c-128g` is $700.80/mo with a **1 GB** disk and
  `storage_type: block_storage`. Both report `gpu_brand: "none"`.
  `Ubuntu 26.04 LTS x64` exists as os_id 2760. All checked against the live
  public Vultr catalogue.
- The cloud-init template was rendered and parsed as YAML across the
  `hashcat = true`, `hashcat = false`, and `extra_packages` +
  `extra_cloud_init` combinations.
- The shell script the template embeds was extracted from the rendered YAML and
  passes `bash -n`, with the `$${…}` template escaping intact —
  `mount-data.sh` renders `${root_disk:=$(basename "$root_src")}`.
- Every package the payload installs is published in Ubuntu 26.04 *resolute*:
  `hashcat 7.1.2+ds1-3` and `clinfo` (universe), `pocl-opencl-icd` (source
  `pocl 6.0-7build1`), `ocl-icd-libopencl1`, `zstd`, `xz-utils`, `tmux` and
  `rsync` (main), `pigz` (universe), `7zip 26.00+dfsg-1` and
  `hcxtools 7.1.0-1` (universe). Checked via the Launchpad API and
  `packages.ubuntu.com`. The template asks for `7zip` rather than `p7zip-full`
  because on 26.04 the latter is only a transitional package.
- **`seclists` is in no Ubuntu suite.** `packages.ubuntu.com/resolute/seclists`
  returns HTTP 200, but the page body is "No such package" — a soft 404 — and a
  cross-suite name search returns nothing. `apt install seclists` would fail on
  this image, so SecLists is cloned from upstream instead.
- The rockyou URL is live and serves what it claims: it 302s to
  `download.weakpass.com`, the gzip header carries the original filename
  `rockyou.txt`, the decompressed head is the canonical list (`123456`,
  `12345`, `123456789`, `password`, …), and the gzip trailer gives an
  uncompressed size of 139,921,497 bytes — 133 MB, matching the classic file at
  a 2.6x ratio off the 53,357,062-byte download.

Carried over from the previous revision of this stack and not re-executed
against the current config:

- The `defaults` inheritance behaviour (bare `crack01 = {}` resolving to the
  full baseline, a deliberate `false` beating a `true` default, snapshot-restored
  instances excluded from OS lookups, deduplicated lookups).
- `snapshot.sh` and `diagnose.sh` against a mock Vultr API.

Not verified, because it needs a live account with billing:

- An actual `tofu apply` creating a real instance.
- **How the 1920 GB actually presents itself.** The plans API says
  `storage_type: local_and_block_storage`, but whether that arrives as a second
  block device or as a larger root disk is not documented and was not observed.
  `mount-data.sh` is written to handle either — it mounts a spare disk if it
  finds one and falls back to creating the directories on the root filesystem if
  it does not — but which branch runs on this plan is unconfirmed. Check
  `df -h /data` on the first real box.
- Whether a Vultr snapshot of such an instance captures the second volume.
  Copy potfiles off explicitly rather than relying on it.
- That hashcat accepts the pocl device without `--force`. hashcat is
  deliberately conservative about non-vendor OpenCL runtimes; `/etc/crackbox/
  backends.txt` records what it actually said on first boot.
- Real cracking throughput. No benchmark was run — the 32-thread-vs-GPU
  comparison in this README is a general statement about CPU versus GPU
  cracking, not a measurement of this plan.
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
