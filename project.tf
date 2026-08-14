# Hosting project: either created here (deterministic ID) or an existing one
# referenced by data source. The WIF pool and service account live here.

resource "google_project" "hosting" {
  count = var.create_project ? 1 : 0

  # A project display name accepts only letters, numbers, hyphen, quotes, space
  # and exclamation point. The Resource Manager API rejects periods, so the
  # dotless "BORIS" is used here rather than the "B.O.R.I.S" spelling that appears
  # in prose.
  name       = "BORIS"
  project_id = local.hosting_project_id

  # Place under a folder when given, otherwise directly under the org.
  org_id    = var.folder_id == "" ? var.organization_id : null
  folder_id = var.folder_id != "" ? var.folder_id : null

  billing_account = var.billing_account != "" ? var.billing_account : null

  # Allow `terraform destroy` to delete the project so offboarding fully removes
  # what this module created (provider default is "PREVENT").
  deletion_policy = "DELETE"
}

data "google_project" "hosting" {
  count      = var.create_project ? 0 : 1
  project_id = local.hosting_project_id
}

# Enable the APIs B.O.R.I.S needs on the hosting project. Do not disable on
# destroy — other workloads in an existing project may depend on them.
resource "google_project_service" "required" {
  for_each = toset(local.required_apis)

  project = local.hosting_project_id
  service = each.value

  disable_on_destroy         = false
  disable_dependent_services = false

  depends_on = [google_project.hosting]
}
