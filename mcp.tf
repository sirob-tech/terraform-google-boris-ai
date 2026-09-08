# The permission that lets boris-reader call GCP's managed MCP servers — the
# cloudcli one behind run_gcloud_command, and the container one behind the live
# Kubernetes reads.
#
# It has to be a custom role. Calling a managed MCP server needs
# mcp.googleapis.com/tools.call, and no predefined role carries it: of the 586
# roles grantable on a project, zero include any mcp.* permission.
#
# Two spellings of one permission, and neither is a typo. IAM custom roles take
# the short service.resource.verb form used here; deny policies take the
# fully-qualified service.googleapis.com/resource.verb form, which is why
# variables.tf spells its denied permissions the other way round.
#
# mcp.googleapis.com is deliberately absent from local.required_apis, because it
# cannot be enabled at all: servicemanagement.services.bind is denied even to a
# project owner. The role and the binding work regardless — the warning that
# `gcloud iam roles create` prints about the unenabled service is cosmetic, and
# the live-access tools were driven end to end against a cluster with the service
# in exactly this state.

resource "google_project_iam_custom_role" "mcp_tool_caller" {
  project     = local.hosting_project_id
  role_id     = var.mcp_custom_role_id
  title       = "B.O.R.I.S MCP Tool Caller"
  description = "Minimal role for calling managed GCP MCP endpoints (cloudcli, container)."
  permissions = ["mcp.tools.call"]

  # Explicit rather than defaulted: a role that silently moved to BETA or
  # DISABLED would drop the live tools with a permission error, and the stage is
  # the only place that would show it.
  stage = "GA"

  # local.hosting_project_id is a plain string, so Terraform infers no dependency
  # on the project or on API enablement. Same reasoning as the service account in
  # wif.tf.
  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "mcp_tool_caller" {
  project = local.hosting_project_id
  role    = google_project_iam_custom_role.mcp_tool_caller.name
  member  = "serviceAccount:${google_service_account.boris_reader.email}"

  # The same ordering rule the org read bindings in iam.tf carry, and for the
  # same reason: this grant is what turns boris-reader's read scope into
  # executable gcloud and Kubernetes reads, so it waits for the guardrail. Wired
  # the other way round, an apply would leave a window where the call permission
  # exists and the deny policy does not — and on destroy it is removed before
  # the deny policy rather than after. No-op when enable_deny_policy = false,
  # since the deny resource then has zero instances.
  depends_on = [google_iam_deny_policy.sensitive_data]
}
