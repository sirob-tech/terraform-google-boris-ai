locals {
  # Deterministic, customer-derived hosting-project ID so a re-apply adopts the
  # same project instead of orphaning a new one. GCP project IDs are 6-30 chars,
  # lowercase; the first 16 hex of the (dash-stripped) customer UUID gives 64
  # bits of entropy (collision-safe at any realistic customer count) while
  # staying within the length limit (prefix is bounded to <=13 chars).
  derived_project_id = "${var.project_id_prefix}-${substr(replace(lower(var.customer_id), "-", ""), 0, 16)}"

  # The project that hosts the WIF pool + service account.
  hosting_project_id = var.project_id != "" ? var.project_id : local.derived_project_id

  # Deny-policy ID, scoped per customer. Deny policies attach to the ORG, and
  # their IDs are unique per attachment point, so a fixed literal would collide
  # whenever two separately-contracted customers target the same org (an
  # enterprise with independent business units). That failure is not benign: the
  # org read bindings and impersonation binding are additive and would apply
  # successfully, so the second customer's boris-reader could end up with
  # org-wide read access while the deny-policy create fails — read access
  # without its guardrail. A customer-derived suffix removes the collision.
  deny_policy_id = "${var.deny_policy_id_prefix}-${substr(replace(lower(var.customer_id), "-", ""), 0, 8)}"

  # Project NUMBER (not ID) — required for the WIF principalSet member.
  hosting_project_number = var.create_project ? google_project.hosting[0].number : data.google_project.hosting[0].number

  # The assumed-role ARN the dedicated B.O.R.I.S role presents after AWS
  # strips the session name (standard attribute.aws_role mapping). This is what
  # the provider's attribute condition and the SA impersonation binding pin.
  assumed_role_arn = "arn:aws:sts::${var.vendor_aws_account_id}:assumed-role/${var.gcp_access_role_name}"

  # CEL mapping applied to the AWS WIF provider. google.subject must stay under
  # 127 bytes, so the assumed-role ARN is normalized to drop the session name.
  # This is Google's standard attribute.aws_role mapping.
  aws_role_mapping = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"

  # Federated principal scoped to the dedicated role only (never pool-wide).
  wif_principal = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.boris.name}/attribute.aws_role/${local.assumed_role_arn}"

  # Required APIs on the hosting project. STS is required for the WIF token
  # exchange; serviceusage is required to read enabled-API state.
  required_apis = [
    "cloudasset.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "serviceusage.googleapis.com",
  ]

  # Sensitive data-plane permissions blocked by the org deny policy. The base set
  # is var.denied_permissions (overridable, defaulted in variables.tf) plus any
  # customer-supplied additions.
  denied_permissions = concat(var.denied_permissions, var.additional_denied_permissions)

  # Full org-role set granted to boris-reader.
  org_roles = concat(var.org_viewer_roles, var.additional_org_roles)

  # A trailing slash is a natural paste, and would otherwise render the
  # registration URL with a double slash. Gateways commonly 404 that path, and a
  # 404 is terminal in the retry loop below — so a stray character would surface
  # as "registration was rejected, check the module inputs" rather than as the
  # typo it is.
  registration_endpoint = trimsuffix(var.registration_endpoint, "/")

  # Registration request body. The organization is NOT in here: it is the tenant
  # and travels in the path, so duplicating it would create two sources for one
  # value. Built with jsonencode rather than a hand-written string so quoting is
  # the encoder's problem, and single-quoted in the shell command — jsonencode
  # emits double quotes and never single ones, so the two cannot collide.
  registration_body = jsonencode({
    project_number        = local.hosting_project_number
    service_account_email = google_service_account.boris_reader.email
  })
}
