# B.O.R.I.S — GCP onboarding Terraform module

Terraform you run in your own Google Cloud organization to grant B.O.R.I.S
read-only access via Workload Identity Federation (WIF) — **no service-account
keys, nothing exported**.

You apply it with your own credentials; B.O.R.I.S never receives an admin token.
After `apply`, a one-line registration call (or optional self-registration) tells
B.O.R.I.S which org, project, and service account to use.

> **Before you start:** registration is authenticated, so you need a
> `connection_secret` issued by the B.O.R.I.S team. Ask for yours before you
> apply — see [The connection secret](#the-connection-secret).

## What it creates

In your organization:

- A **WIF pool + AWS provider** trusting only the per-customer B.O.R.I.S **vendor
  AWS account**, pinned to the dedicated `boris-ai-gcp-access` role (account-ID
  pinning alone would trust every role in that account).
- A **`boris-reader` service account** and the `roles/iam.workloadIdentityUser`
  binding that lets the federated identity impersonate it.
- **Org-level read-only role bindings**: `roles/viewer`, `roles/browser`,
  `roles/iam.securityReviewer`, `roles/cloudasset.viewer`,
  `roles/serviceusage.serviceUsageViewer`.
- A **sensitive-data deny policy** (org-level) blocking data-plane reads
  (Secret Manager, GCS object reads, SA key/token operations, BigQuery table
  data, Datastore/Spanner/Pub-Sub payloads, KMS decrypt) for `boris-reader`.
  Required by default; disable with `enable_deny_policy = false`.
- Required APIs enabled on a **hosting project** (created with a deterministic,
  customer-derived ID, or an existing one you supply).

### Read scope, and what the deny policy does not cover

The role set above is a broad read-only set of predefined roles rather than a
minimal enumerated one. `roles/viewer` in particular is a broad basic role, and
the deny policy blocks an **explicit list of specific permissions** — it is not a
general filter over everything `roles/viewer` grants.

So there are secret-bearing read paths that a broad role set can allow and the
default deny list does not block. The ones we know of, with the permission to add
to `additional_denied_permissions` if it matters in your org:

| Uncovered read path | Add to `additional_denied_permissions` |
|---|---|
| Compute instance metadata and startup scripts | `compute.googleapis.com/instances.get` |
| Serial port output, which can echo boot-time secrets | `compute.googleapis.com/instances.getSerialPortOutput` |
| Cloud Run and Cloud Functions service configs, whose `get` responses include plaintext environment variables | `run.googleapis.com/services.get`, `cloudfunctions.googleapis.com/functions.get` |
| Cloud Logging entries, a common place for secrets and PII to land | `logging.googleapis.com/logEntries.list` |

Every permission above is verified against Google's
[permissions supported in deny policies](https://cloud.google.com/iam/docs/deny-permissions-support).
That list matters: **a deny policy naming an unsupported permission is rejected**,
so check any addition of your own against it rather than inferring the string from
an IAM role reference.

**One gap the deny policy cannot close: GKE Kubernetes Secrets.** Deny policies
support only `clusters.*` and `operations.*` for `container.googleapis.com`, so
`container.secrets.*` cannot be denied at all — there is no permission to add. If
your clusters hold Secrets and your org maps basic roles onto Kubernetes RBAC, the
lever is `org_viewer_roles`: drop `roles/viewer` for a narrower set such as
`roles/container.viewer`, which does not grant Secret access. Confirm what your own
org grants with `gcloud iam roles describe roles/viewer`.

This table is what we are aware of, not a proof of exhaustiveness — `roles/viewer`
is a basic role and Google can widen it. To audit the remainder, diff
`gcloud iam roles describe roles/viewer` against the `denied_permissions` default
in [`variables.tf`](variables.tf). If you find a gap worth blocking by default,
tell the B.O.R.I.S team.

Moving secrets into Secret Manager also closes them off, since the deny policy
blocks that service in full (`secretmanager.googleapis.com/*.*`).

### Everything here is an input you control

Neither the granted roles nor the deny list is baked in. Both are variables whose
defaults are what B.O.R.I.S ships, so you can read them, extend them, or replace them
in your own Terraform:

| Variable | Default | Use it to |
|---|---|---|
| `org_viewer_roles` | the read-only role set above | Replace the granted roles with a narrower set |
| `additional_org_roles` | `[]` | Grant additional roles |
| `denied_permissions` | the full deny list | Replace the guardrail outright |
| `additional_denied_permissions` | `[]` | Keep the shipped guardrail and block more |
| `enable_deny_policy` | `true` | Opt out of the deny policy entirely |

`denied_permissions` and `additional_denied_permissions` are concatenated, so
extending the default set never means restating it. Narrowing `org_viewer_roles`
or shrinking `denied_permissions`' scope is your call to make — but B.O.R.I.S features
that depend on the defaults may degrade, and a smaller deny list means a weaker
guardrail on the read access you have already granted.

## Usage

```hcl
module "boris_gcp" {
  source  = "sirob-tech/boris-ai/google"
  version = "~> 1.0"

  customer_id           = "00000000-0000-0000-0000-000000000000"
  organization_id       = "123456789012"
  vendor_aws_account_id = "111122223333" # from your B.O.R.I.S install link

  # Create a hosting project (or set project_id to reuse an existing one):
  create_project  = true
  billing_account = "XXXXXX-XXXXXX-XXXXXX"
}

output "register" { value = module.boris_gcp.registration_curl }
```

Then register (fallback manual path). The secret comes from your shell, not from
Terraform — see [The connection secret](#the-connection-secret):

```
export BORIS_CONNECTION_SECRET='boris_...'
curl -X PUT 'https://install.getboris.ai/gcp/install/<org_id>' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $BORIS_CONNECTION_SECRET" \
  -d '{"project_number":"<n>","service_account_email":"<sa>"}'
```

Or set `enable_self_registration = true`, `registration_endpoint` and
`connection_secret` to have the module PUT it for you inside `apply` (idempotent
on re-apply).

### The connection secret

The B.O.R.I.S team issues you a per-connection secret that looks like
`boris_<16 chars>_<52 chars>`. It authenticates the registration call, and your
customer identity is derived from it — which is why `customer_id` does not appear
in the registration URL.

Three things worth knowing:

- **It is not single-use.** It binds to your organization the first time it is
  used and stays valid, so keep it available: a later `terraform apply` that
  changes a registered value will call the endpoint again.
- **Keep it out of state.** Pass it via `TF_VAR_connection_secret` in your
  environment or a secrets manager, not a committed `.tfvars`. The module never
  writes it to state: it is excluded from `triggers_replace`, reaches `local-exec`
  only through the provisioner `environment` block, and the `registration_curl`
  output references `$BORIS_CONNECTION_SECRET` rather than embedding the value.
  One thing that is outside the module's control: a **saved plan file**
  (`terraform plan -out=…`, the usual CI pattern) records root-module variable
  values, and `sensitive = true` suppresses display but not storage. Treat plan
  artifacts as secret-bearing.
- **A rejected secret is not retried.** Any 4xx — a refused secret (401), a
  conflict (409), or a rejected identifier — fails `apply` immediately rather than
  retrying, because those states do not clear on their own. A 401 or 409 needs the
  B.O.R.I.S team to resolve.

Runnable configurations for both shapes are in
[`examples/`](examples): `create-project` (module creates the hosting project)
and `existing-project` (reuse your own project, with self-registration on).

### One organization per customer

Register **one GCP org per `customer_id`**: the registration endpoint rejects a
second, different org for the same customer.

It also matters here: the derived hosting-project ID is keyed on `customer_id`
and `project_id_prefix` only, not on `organization_id`. Since GCP project IDs are
globally unique, applying this module twice for one `customer_id` against two
orgs derives the *same* project ID and the second `apply` fails with "already
exists". If you genuinely need a second org, set an explicit distinct
`project_id` (or `project_id_prefix`) for it and talk to the B.O.R.I.S team first —
the mapping will not accept both.

### Registration timing

Registration records the values you send; it does not exercise the WIF chain, so
it does not block on GCP IAM propagation. That propagation is still real — org
role bindings, the service-account impersonation binding, and the deny policy can
take minutes to become effective after their create calls return — so B.O.R.I.S's
first reads against your org may fail for a few minutes after a successful
registration, and then begin working with no action from you.

Self-registration retries anything that is not a 2xx or a 4xx — 5xx, an
unexpected redirect, and transport failures: seven attempts with about four
minutes of backoff between them. Each attempt can also spend up to its 60-second
`--max-time`, so a fully stalled endpoint holds `apply` for up to roughly eleven
minutes before failing. Any 4xx —
including a refused secret (401) and a conflicting registration (409) — fails
immediately instead, since those do not clear on their own.

## Deployer prerequisites

The admin applying this module needs, at the org level:

- `roles/iam.workloadIdentityPoolAdmin` — WIF pool/provider
- `roles/iam.serviceAccountAdmin` — the service account
- `roles/iam.securityAdmin` (or `roles/resourcemanager.organizationAdmin`) — org
  role bindings. Note that `roles/iam.organizationRoleAdmin` is **not** an
  alternative: it administers custom role definitions and carries no
  `resourcemanager.organizations.setIamPolicy`, so the bindings fail with a 403
  after the project, pool, and service account already exist.
- `roles/iam.denyAdmin` — the deny policy (only if `enable_deny_policy = true`)
- `roles/serviceusage.serviceUsageAdmin` — enabling APIs

With `create_project = true`, also:

- `roles/resourcemanager.projectCreator` — creating the hosting project
- `roles/billing.user` **on the billing account** (not on the org) — only if you
  set `billing_account`. Associating a billing account needs
  `billing.resourceAssociations.create`, which no org-level role above grants.
Deleting the hosting project on `terraform destroy` usually needs no extra grant:
whoever creates a project is granted Owner on it, which already permits deletion.
You only need `roles/resourcemanager.projectDeleter` if that Owner grant was
removed, or if a different principal runs the destroy than ran the apply.

### Org-policy constraints that block WIF provider **creation**

These list constraints, if set, cause `apply` to fail when the provider is
**created/updated** (grandfathered providers are unaffected). Check both the
legacy and the newer `iam.managed.*` forms:

- `constraints/iam.workloadIdentityPoolAwsAccounts` — must allowlist the B.O.R.I.S
  vendor AWS account (`vendor_aws_account_id`).
- `constraints/iam.workloadIdentityPoolProviders` — must allow
  `https://sts.amazonaws.com`.

> **Warning — access-severing changes after onboarding.** Two inputs must not be
> changed once a customer is live with `create_project = true`:
>
> - Flipping `create_project` from `true` to `false` on a project this module
>   created. Terraform will plan to **destroy** that project (and the WIF pool,
>   provider, and SA in it), not adopt it. To reuse a module-created project,
>   keep `create_project = true`.
> - Changing `project_id_prefix`. GCP project IDs are **immutable**, so a new
>   prefix yields a new derived ID and Terraform destroys and recreates the
>   hosting project — taking the WIF pool, provider, and `boris-reader` with it.
>   Access is severed mid-apply and both `project_number` and
>   `service_account_email` change, so the org must be re-registered with B.O.R.I.S.
>
> Set both at onboarding time and leave them alone. To move an existing customer
> to a different project, coordinate with the B.O.R.I.S team so the mapping is
> re-registered.

### Verify `organization_id` before you apply

Nothing in this module cross-checks that the hosting project actually lives in
the org you named. The org role bindings and the deny policy are applied to
`organization_id` directly, while the project/WIF/SA resources go wherever
`project_id` or `folder_id` resolves to — so a mistyped `organization_id` grants
`boris-reader` read access to the **wrong organization**, with the identity infra
sitting in the intended one.

Most typos fail loudly, because the deployer usually lacks org-admin on the
mistyped org and the binding is rejected. The case to watch is an admin with
rights over **several** orgs, where both halves succeed independently. Confirm
with `gcloud organizations list` before applying, and check the plan's
`google_organization_iam_member` entries name the org you expect.

### Reusing a project that already has a WIF pool or `boris-reader`

If the project you point at (`create_project = false`) already contains a
`boris-aws` pool or a `boris-reader` service account, `apply` fails with "already
exists" — Terraform will not adopt resources it did not create. Either let the
module create a fresh hosting project, or `terraform import` the existing pool,
provider, and service account into state first.

## Offboarding

`terraform destroy` removes all customer-side access (pool, provider, SA,
bindings, deny policy, and the hosting project if this module created it). It
does **not** call the B.O.R.I.S DELETE endpoint — that is authenticated/team-only;
ask the B.O.R.I.S team to deregister the mapping.

### Re-onboarding after a destroy

`destroy` is clean, but GCP retains two kinds of name reservation that make a
later re-`apply` under the same inputs fail. Neither is a problem with your
config, and both have a fix:

| What you see on re-apply | Why | Fix |
|---|---|---|
| Project `... already in use` | **Project IDs are never reusable**, even after the project is fully deleted. The derived ID is keyed on `customer_id`, so it resolves to the same permanently-burned ID. | Set a different `project_id_prefix`, or pass an explicit `project_id`. Tell the B.O.R.I.S team, since `project_number` changes. |
| WIF pool or provider `already exists` | Pools and providers are **soft-deleted for 30 days**, and the name stays reserved for that window. | `gcloud iam workload-identity-pools undelete <pool> --location=global` (and `... providers undelete`) to recover in place, or wait out the window, or choose different `wif_pool_id` / `wif_provider_id` — the last option needs coordination, since those are contract strings. |

If you are recovering from a bad `apply` rather than genuinely offboarding,
prefer `undelete` over changing IDs: it restores the original names and leaves
the contract strings B.O.R.I.S relies on intact.

## Versioning and upgrades

This module is released with semantic versioning, and the version you pin
determines exactly what access you have granted. Pin it:

```hcl
source  = "sirob-tech/boris-ai/google"
version = "~> 1.0"
```

What the version numbers mean here:

- **Major** — a change you should review before adopting: a new role or
  permission in the granted set, a removal from the deny list, or a breaking
  input change. B.O.R.I.S capabilities that need broader access ship this way, rather
  than silently widening what an existing pin already grants.
- **Minor** — new optional inputs, new outputs, additional guardrails.
- **Patch** — fixes and documentation.

To upgrade, bump the constraint and run `terraform init -upgrade`, then read the
plan before applying. The plan is the authoritative diff of what changes in your
org: a release that widens read scope shows up as new
`google_organization_iam_member` resources, and one that changes the guardrail
shows up as a change to `google_iam_deny_policy`. Nothing changes until you
apply, so a new release never alters B.O.R.I.S's access on its own.

Downgrading works the same way, though re-narrowing scope may degrade B.O.R.I.S
features that relied on the wider set.

## Notes / contracts

- `wif_pool_id` / `wif_provider_id` / `gcp_access_role_name` are **contract
  strings** shared with the B.O.R.I.S side, which addresses your pool and provider —
  and the AWS role it assumes — by these exact IDs. Current values: `boris-aws` /
  `aws-sts` / `boris-ai-gcp-access`. Change them only if the B.O.R.I.S team asks
  you to. These IDs are **not** part of the registration call, so a mismatch does
  not surface at `apply` or at registration: both succeed, and the credential
  exchange fails later when B.O.R.I.S first tries to use the pool. If you change
  one, tell the B.O.R.I.S team in the same breath.
- Pool and provider IDs are both constrained by GCP to **4-32 characters** of
  `[a-z0-9-]` with `gcp-` reserved. The module validates length, charset, and the
  reserved prefix at plan time, which catches the common too-short mistake; it does
  not reproduce every GCP naming rule, so an exotic value (a leading or trailing
  hyphen, for instance) can still fail partway through `apply`.
- The deny list is an explicit, auditable set of permissions — read the
  `denied_permissions` default in `variables.tf` before you apply. It is expressed
  as an org-level control that you own and can inspect, extend, replace, or
  disable outright. See the table above.

## License

[Apache License 2.0](LICENSE). You are free to use, modify, and redistribute this
module, including forking it to adjust the granted scope for your own org.

Apache-2.0 §6 grants no trademark rights: the license covers this module's
source, not the B.O.R.I.S name or logo. Forks are welcome, but must not be
distributed under the B.O.R.I.S name.
