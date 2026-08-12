SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TOFU    ?= tofu
PROJECT ?= containerlabs

export PROJECT

.PHONY: help init bootstrap objstore check fmt plan apply destroy snapshot snapshots prune diagnose dns regions plans os lint

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

# --- OpenTofu ----------------------------------------------------------------

init: ## tofu init against the Vultr Object Storage state backend
	@test -f backend.hcl || { echo "backend.hcl missing -- run: make bootstrap"; exit 1; }
	$(TOFU) init -backend-config=backend.hcl

bootstrap: ## Create the state bucket in Vultr Object Storage and write backend.hcl
	bash scripts/bootstrap-backend.sh $(if $(BUCKET),--bucket $(BUCKET),)

objstore: ## List Vultr Object Storage subscriptions and their buckets
	bash scripts/bootstrap-backend.sh --list

check: ## Format check + validate, without touching remote state
	$(TOFU) fmt -check -recursive -diff
	@$(TOFU) init -backend=false -input=false >/dev/null
	@# The provider schema marks api_key required, so `validate` insists on a
	@# value even though it never calls the API. A placeholder is enough.
	VULTR_API_KEY=$${VULTR_API_KEY:-placeholder-for-validate} $(TOFU) validate

fmt: ## Rewrite HCL into canonical format
	$(TOFU) fmt -recursive

plan: ## Plan the whole fleet
	$(TOFU) plan -out=tofu.plan

apply: ## Apply the plan saved by `make plan`
	$(TOFU) apply tofu.plan

destroy: ## Destroy the whole fleet (interactive confirmation)
	$(TOFU) destroy

# --- Operations --------------------------------------------------------------

snapshot: ## Snapshot every instance in the project
	bash scripts/snapshot.sh create --all --wait

snapshots: ## List this project's snapshots
	bash scripts/snapshot.sh list

prune: ## Dry-run a prune keeping the 3 newest per instance (KEEP=n to change)
	bash scripts/snapshot.sh prune --keep $(or $(KEEP),3) --dry-run

diagnose: ## Read-only health report
	bash scripts/diagnose.sh

dns: ## Sync Cloudflare A/AAAA records to the fleet (DRY_RUN=1 to preview)
	bash scripts/dns-sync.sh --prune $(if $(DRY_RUN),--dry-run,)

# --- Vultr catalogue (public endpoints, no API key needed) -------------------

regions: ## List Vultr regions
	@curl -fsSL https://api.vultr.com/v2/regions \
	  | jq -r '.regions[] | [.id, "\(.city), \(.country)"] | @tsv' \
	  | column -t -s $$'\t'

plans: ## List plans available in REGION (default lax). e.g. make plans REGION=ewr
	@curl -fsSL 'https://api.vultr.com/v2/plans?per_page=500' \
	  | jq -r --arg r '$(or $(REGION),lax)' \
	      '.plans[] | select(.locations | index($$r)) | [.id, .type, (.cpu_vendor // "-"), "\(.vcpu_count) vCPU", "\(.ram) MB", "\(.disk) GB", "$$\(.monthly_cost)/mo"] | @tsv' \
	  | sort -t $$'\t' -k7 -n \
	  | column -t -s $$'\t'

os: ## List Vultr OS images (the name goes in os_name)
	@curl -fsSL https://api.vultr.com/v2/os \
	  | jq -r '.os[] | [.id, .name] | @tsv' \
	  | column -t -s $$'\t'

# --- Linting -----------------------------------------------------------------

lint: ## shellcheck the operational scripts
	shellcheck -x scripts/*.sh
