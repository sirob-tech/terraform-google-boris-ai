# Workload Identity Federation: a pool + AWS provider trusting the per-customer
# B.O.R.I.S vendor account, pinned to the dedicated boris-ai-gcp-access role; a
# read-only service account; and the impersonation binding that ties them.

resource "google_iam_workload_identity_pool" "boris" {
  project                   = local.hosting_project_id
  workload_identity_pool_id = var.wif_pool_id
  display_name              = "B.O.R.I.S AWS Pool"
  description               = "Allows B.O.R.I.S running on AWS to access this GCP org read-only via WIF."

  depends_on = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  project                            = local.hosting_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.boris.workload_identity_pool_id
  workload_identity_pool_provider_id = var.wif_provider_id
  display_name                       = "AWS"
  description                        = "B.O.R.I.S AWS provider"

  aws {
    account_id = var.vendor_aws_account_id
  }

  # aws_role stays normalized because attribute_condition and the impersonation
  # binding both address it. subject and session_name carry the session name so
  # the customer's audit log can tell one conversation from another.
  attribute_mapping = {
    "google.subject"             = local.aws_subject_mapping
    "attribute.aws_role"         = local.aws_role_mapping
    "attribute.aws_session_name" = local.aws_session_name_mapping
  }

  # Account-ID pinning alone trusts EVERY role in the vendor account. Restrict
  # to the dedicated boris-ai-gcp-access role via the normalized aws_role.
  attribute_condition = "attribute.aws_role == '${local.assumed_role_arn}'"
}

resource "google_service_account" "boris_reader" {
  project      = local.hosting_project_id
  account_id   = var.service_account_id
  display_name = "B.O.R.I.S Reader"
  description  = "Read-only identity B.O.R.I.S impersonates via Workload Identity Federation."

  # project is a plain string local, so Terraform infers no dependency on the
  # project / API enablement — make it explicit so a first apply with
  # create_project = true does not race ahead of the project or iam API.
  depends_on = [google_project_service.required]
}

# The glue: let the federated principal (scoped to the dedicated role, never
# pool-wide) impersonate boris-reader. Without this the whole WIF chain fails.
resource "google_service_account_iam_member" "wif_impersonation" {
  service_account_id = google_service_account.boris_reader.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_principal
}
