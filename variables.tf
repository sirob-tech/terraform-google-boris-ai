# ---------------------------------------------------------------------------
# Identity / contract inputs
# ---------------------------------------------------------------------------

variable "customer_id" {
  type        = string
  description = "B.O.R.I.S customer UUID. Keys the deterministic hosting-project ID and the deny-policy ID. It is not sent to the registration endpoint — registration identifies you by your connection secret."

  # Full UUID shape, not just the charset. Two things depend on the length:
  # locals.tf takes the first 16 hex characters of the dash-stripped value for
  # the derived project ID, and Terraform's substr() silently truncates rather
  # than erroring — so a short-but-hex-looking value would quietly yield far
  # less than the 64 bits of entropy that derivation assumes. Restricting to
  # hex-and-dashes also keeps shell metacharacters out of the self-registration
  # local-exec command.
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.customer_id))
    error_message = "customer_id must be a full UUID, e.g. \"123e4567-e89b-12d3-a456-426614174000\"."
  }
}

variable "organization_id" {
  type        = string
  description = "Numeric GCP organization ID (digits only, e.g. \"123456789012\") where B.O.R.I.S read-only access is granted."

  validation {
    condition     = can(regex("^[0-9]+$", var.organization_id))
    error_message = "organization_id must be the numeric org ID (digits only), not \"organizations/<id>\"."
  }
}

variable "vendor_aws_account_id" {
  type        = string
  description = "The per-customer B.O.R.I.S (vendor) AWS account ID that the WIF provider trusts. Appears in the B.O.R.I.S install link; not secret."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.vendor_aws_account_id))
    error_message = "vendor_aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "gcp_access_role_name" {
  type        = string
  description = "Name of the dedicated AWS-side IAM role, in the B.O.R.I.S AWS account, that the WIF provider pins. B.O.R.I.S workloads assume this role and then federate into GCP; pinning it means the provider trusts only that role rather than every identity in the account. Fixed contract string — leave at the default unless the B.O.R.I.S team says otherwise."
  default     = "boris-ai-gcp-access"

  # Restricted to AWS's IAM role-name charset (1-64 of [\w+=,.@-]). Notably this
  # excludes the single quote, which matters because the value is spliced into
  # the single-quoted CEL literal in wif.tf's attribute_condition — a quote here
  # could otherwise terminate the literal and widen the trust condition beyond
  # the intended role.
  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]{1,64}$", var.gcp_access_role_name))
    error_message = "gcp_access_role_name must be a valid AWS IAM role name: 1-64 characters from [a-zA-Z0-9+=,.@_-]."
  }
}

# ---------------------------------------------------------------------------
# Hosting project
# ---------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "Existing GCP project ID that hosts the WIF pool and boris-reader service account. Leave empty to have the module create one (see create_project) with a deterministic, customer-derived ID so re-applies adopt rather than orphan."
  default     = ""

  # When not creating a project, an explicit project_id is required — otherwise
  # the module would fall through to a derived ID that matches no real project
  # and fail with a confusing "not found" from the data source.
  validation {
    condition     = var.create_project || length(var.project_id) > 0
    error_message = "project_id is required when create_project is false."
  }
}

variable "create_project" {
  type        = bool
  description = "When true, the module creates the hosting project (deterministic ID derived from customer_id unless project_id is set). When false, project_id must reference an existing project. WARNING: do not flip this from true to false on an already-created project — Terraform will DESTROY the created project (and everything in it) rather than adopt it. To reuse a module-created project, keep create_project = true."
  default     = false
}

variable "project_id_prefix" {
  type        = string
  description = "Prefix for the deterministic hosting-project ID when create_project is true and project_id is empty. Final ID is \"<prefix>-<first 16 hex of customer_id>\"."
  default     = "boris"

  # Bounded so "<prefix>-<16 hex>" stays within the 30-char GCP project-ID
  # limit, and constrained to valid project-ID characters (lowercase, start
  # with a letter) so the derived ID is always valid.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,12}$", var.project_id_prefix))
    error_message = "project_id_prefix must be 1-13 chars, lowercase letters/digits/hyphens, starting with a letter (so <prefix>-<16 hex> fits GCP's 30-char project-ID limit)."
  }
}

variable "folder_id" {
  type        = string
  description = "Optional folder ID to place a created hosting project under. When empty, the project is created directly under organization_id. Ignored unless create_project is true."
  default     = ""
}

variable "billing_account" {
  type        = string
  description = "Optional billing account ID to associate with a created hosting project. Ignored unless create_project is true."
  default     = ""
}

# ---------------------------------------------------------------------------
# Workload Identity Federation naming
#
# These IDs are a shared contract with the B.O.R.I.S side: the B.O.R.I.S WIF
# exchange addresses your pool and provider by these exact IDs. Leave them at
# their defaults unless the B.O.R.I.S team asks you to change them.
# ---------------------------------------------------------------------------

variable "wif_pool_id" {
  type        = string
  description = "Workload Identity Pool ID. Fixed contract string shared with the B.O.R.I.S side."
  default     = "boris-aws"

  # GCP requires pool IDs to be 4-32 chars of [a-z0-9-], with "gcp-" reserved.
  # Validated here so a bad value fails at plan time with a clear message
  # instead of an opaque API error partway through apply.
  validation {
    condition     = can(regex("^[a-z0-9-]{4,32}$", var.wif_pool_id)) && !startswith(var.wif_pool_id, "gcp-")
    error_message = "wif_pool_id must be 4-32 characters of [a-z0-9-] and must not start with the reserved prefix \"gcp-\"."
  }
}

variable "wif_provider_id" {
  type        = string
  description = "AWS Workload Identity Pool Provider ID. Fixed contract string shared with the B.O.R.I.S side; it identifies the AWS STS issuer (https://sts.amazonaws.com) that the provider trusts."
  default     = "aws-sts"

  # Same 4-32 / [a-z0-9-] / no-"gcp-" rule as the pool ID. This one bites: a
  # plausible-looking "aws" is only 3 characters and is rejected by the API, so
  # it is worth catching at plan time rather than partway through apply.
  validation {
    condition     = can(regex("^[a-z0-9-]{4,32}$", var.wif_provider_id)) && !startswith(var.wif_provider_id, "gcp-")
    error_message = "wif_provider_id must be 4-32 characters of [a-z0-9-] and must not start with the reserved prefix \"gcp-\"."
  }
}

# ---------------------------------------------------------------------------
# Service account and org-level roles
# ---------------------------------------------------------------------------

variable "service_account_id" {
  type        = string
  description = "Account ID (local part) of the read-only service account B.O.R.I.S impersonates."
  default     = "boris-reader"

  # GCP service-account ID rules (6-30 chars, lowercase, start with a letter).
  # Also shell-injection defense: the derived SA email is spliced into the
  # self-registration local-exec command.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.service_account_id))
    error_message = "service_account_id must be 6-30 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "org_viewer_roles" {
  type        = list(string)
  description = "Org-level roles granted to the boris-reader service account. The default is a broad read-only set; substitute a narrower list to reduce read scope, at the cost of B.O.R.I.S features that depend on it."
  default = [
    "roles/viewer",
    "roles/browser",
    "roles/iam.securityReviewer",
    "roles/cloudasset.viewer",

    # Consumer rather than the narrower serviceUsageViewer, and the difference
    # is exactly one permission: serviceusage.services.use. Several gcloud
    # surfaces — Cloud Storage measurably, and any API that bills a request to a
    # user project — refuse every read without it, including pure metadata
    # reads. Measured: `gcloud storage buckets list` and `buckets describe` both
    # returned 403 "does not have serviceusage.services.use access" under
    # serviceUsageViewer, in every project rather than only in some.
    #
    # It is not a data-access grant. It makes boris-reader a *consumer* of the
    # project, which is what lets a request be attributed to it — so it does let
    # B.O.R.I.S spend your API quota, and grants nothing further.
    "roles/serviceusage.serviceUsageConsumer",
  ]
}

variable "additional_org_roles" {
  type        = list(string)
  description = "Extra org-level roles to grant boris-reader beyond org_viewer_roles."
  default     = []
}

# ---------------------------------------------------------------------------
# Live access (managed MCP)
# ---------------------------------------------------------------------------

variable "mcp_custom_role_id" {
  type        = string
  description = "Role ID of the custom role carrying mcp.tools.call, which lets boris-reader call GCP's managed MCP servers. Project-scoped, so a fixed literal is safe here — unlike the deny policy, which attaches to the shared organization and needs a per-customer suffix. Role IDs beginning \"goog\" are reserved by Google."
  default     = "borisMcpToolCaller"

  # GCP custom role IDs are 3-64 characters of letters, digits, underscores and
  # periods. Validated here so a bad value fails at plan time rather than partway
  # through apply. The reserved-prefix rule is documented above rather than
  # encoded, so a future legitimate value is not blocked by a guess.
  validation {
    condition     = can(regex("^[a-zA-Z0-9_.]{3,64}$", var.mcp_custom_role_id))
    error_message = "mcp_custom_role_id must be 3-64 characters of letters, digits, \"_\" or \".\"."
  }
}

# ---------------------------------------------------------------------------
# Sensitive-data deny policy (required by default)
# ---------------------------------------------------------------------------

variable "enable_deny_policy" {
  type        = bool
  description = "When true (default), attach an org-level IAM deny policy blocking sensitive data-plane reads for boris-reader. Applying it requires roles/iam.denyAdmin at the org level. Set false to opt out."
  default     = true
}

variable "deny_policy_id_prefix" {
  type        = string
  description = "Prefix for the org-level deny-policy ID. The final ID is \"<prefix>-<first 8 hex of customer_id>\", keeping it unique per customer because deny policies attach to the shared organization."
  default     = "boris-deny-sensitive-data"

  # GCP deny-policy IDs are 3-63 characters of lowercase letters, digits, "-"
  # and ".", and must start with a lowercase letter. Bounded to 54 here so the
  # "-<8 hex>" suffix keeps the final ID inside the 63-character limit.
  validation {
    condition     = can(regex("^[a-z][a-z0-9.-]{2,53}$", var.deny_policy_id_prefix))
    error_message = "deny_policy_id_prefix must be 3-54 characters of lowercase letters, digits, \".\" or \"-\", starting with a lowercase letter (so \"<prefix>-<8 hex>\" fits GCP's 63-character deny-policy ID limit)."
  }
}

variable "denied_permissions" {
  type        = list(string)
  description = "The full set of permissions the deny policy blocks for boris-reader. The default is the complete guardrail B.O.R.I.S ships; override it to replace the set outright. To keep the default and add to it, use additional_denied_permissions instead — the two are concatenated."

  default = [
    # Secret Manager, in full — secret payloads and metadata alike.
    "secretmanager.googleapis.com/*.*",

    # Object payloads in Cloud Storage. Bucket metadata stays readable, so
    # configuration and policy review still work.
    "storage.googleapis.com/objects.get",
    "storage.googleapis.com/objects.list",

    # Service-account key material and token minting. Without these, a read-only
    # identity cannot mint credentials for any other identity in the org.
    "iam.googleapis.com/serviceAccountKeys.create",
    "iam.googleapis.com/serviceAccountKeys.delete",
    "iam.googleapis.com/serviceAccountKeys.get",
    "iam.googleapis.com/serviceAccountKeys.list",
    "iam.googleapis.com/serviceAccounts.getAccessToken",
    "iam.googleapis.com/serviceAccounts.getOpenIdToken",
    "iam.googleapis.com/serviceAccounts.signBlob",
    "iam.googleapis.com/serviceAccounts.signJwt",

    # Decryption via KMS.
    "cloudkms.googleapis.com/cryptoKeyVersions.useToDecrypt",

    # Row-level data in analytics and database services. Schema and
    # configuration metadata remain readable.
    "bigquery.googleapis.com/tables.getData",
    "datastore.googleapis.com/entities.get",
    "datastore.googleapis.com/entities.list",
    "spanner.googleapis.com/sessions.create",
    "pubsub.googleapis.com/subscriptions.consume",

    # Live credentials and source, which roles/viewer grants and the original
    # list missed. getKeyString is the sharpest: it returns a usable API key
    # rather than metadata about one, which is a different category from the
    # configuration-disclosure paths above.
    "apikeys.googleapis.com/keys.getKeyString",
    "cloudfunctions.googleapis.com/functions.sourceCodeGet",

    # Vertex AI agent memory, sessions and cached prompts. These hold arbitrary
    # user-supplied content, which for this module's audience is the most likely
    # place for a customer's own end-user data to sit.
    "aiplatform.googleapis.com/memories.get",
    "aiplatform.googleapis.com/memories.list",
    "aiplatform.googleapis.com/memories.retrieve",
    "aiplatform.googleapis.com/sessions.get",
    "aiplatform.googleapis.com/sessions.list",
    "aiplatform.googleapis.com/sessionEvents.list",
    "aiplatform.googleapis.com/cachedContents.get",
    "aiplatform.googleapis.com/cachedContents.list",

    # Every string above was verified against a live deny policy before shipping,
    # not against the documentation. That check is not optional: an unsupported
    # permission is rejected at CREATE time, so it would fail every customer's
    # apply rather than failing review. It caught two —
    # runtimeconfig.googleapis.com/variables.get and .list are NOT deniable,
    # though roles/viewer grants both. They are listed in the README as an
    # uncovered path instead, because that is what they are.
  ]

  # A deny rule with no permissions is rejected by the API, which would surface
  # as an opaque failure partway through apply. Caught at plan time instead.
  validation {
    condition     = !var.enable_deny_policy || length(var.denied_permissions) > 0
    error_message = "denied_permissions must list at least one permission when enable_deny_policy is true. To run without a deny policy, set enable_deny_policy = false explicitly."
  }
}

variable "additional_denied_permissions" {
  type        = list(string)
  description = "Extra permissions to append to denied_permissions, e.g. \"compute.googleapis.com/instances.get\" to also block reading instance metadata. Use this to keep the shipped guardrail and extend it; use denied_permissions to replace it."
  default     = []
}

# ---------------------------------------------------------------------------
# Optional self-registration (single-apply onboarding)
# ---------------------------------------------------------------------------

variable "enable_self_registration" {
  type        = bool
  description = "When true, the module calls the B.O.R.I.S registration endpoint after creating resources (idempotent PUT via local-exec). When false (default), copy the outputs into a manual curl PUT."
  default     = false
}

variable "registration_endpoint" {
  type        = string
  description = "Base URL of the B.O.R.I.S registration endpoint (e.g. https://install.getboris.ai). Required when enable_self_registration is true."
  default     = ""

  validation {
    condition     = !var.enable_self_registration || length(var.registration_endpoint) > 0
    error_message = "registration_endpoint is required when enable_self_registration is true."
  }

  # Must be a plain https URL with no shell metacharacters — it is spliced into
  # the self-registration local-exec command.
  validation {
    condition     = var.registration_endpoint == "" || can(regex("^https://[A-Za-z0-9.:/_-]+$", var.registration_endpoint))
    error_message = "registration_endpoint must be an https:// URL containing only letters, digits, and . : / _ -"
  }
}

variable "connection_secret" {
  type        = string
  description = "Per-connection onboarding secret issued by the B.O.R.I.S team, sent as an Authorization: Bearer credential. Required when enable_self_registration is true. It is not single-use: it binds to your organization on first use and stays valid, so keep it available for re-apply."
  default     = ""
  sensitive   = true

  validation {
    condition     = !var.enable_self_registration || length(var.connection_secret) > 0
    error_message = "connection_secret is required when enable_self_registration is true. Ask the B.O.R.I.S team to issue one for your customer record."
  }

  # Exact shape, not just a prefix. The token is boris_<key_id>_<secret> where
  # both halves are unpadded lowercase base32 (alphabet a-z and 2-7) of fixed
  # length — 16 and 52 characters. The realistic failure is a truncated or
  # partially-selected paste, and catching that at plan time is worth the
  # coupling: the alternative is a 401 that the retry logic must treat as
  # terminal, several seconds into an apply that already created real
  # infrastructure.
  validation {
    condition     = var.connection_secret == "" || can(regex("^boris_[a-z2-7]{16}_[a-z2-7]{52}$", var.connection_secret))
    error_message = "connection_secret must look like boris_<16 chars>_<52 chars>, using only lowercase letters and the digits 2-7. Check for a truncated copy-paste."
  }
}
