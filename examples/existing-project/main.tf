# Onboarding into a hosting project you already manage, with self-registration
# enabled so a single `terraform apply` completes onboarding end to end.
#
# The project must not already contain a WIF pool named boris-aws or a
# boris-reader service account — Terraform will not adopt resources it did not
# create, and apply fails with "already exists".

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.41.0"
    }
  }
}

provider "google" {}

variable "connection_secret" {
  type        = string
  description = "Per-connection secret issued by the B.O.R.I.S team. Supply it as TF_VAR_connection_secret rather than putting it in a committed .tfvars."
  sensitive   = true
}

module "boris_gcp" {
  # Published as:
  #   source  = "sirob-tech/boris-ai/google"
  #   version = "~> 2.0"
  source = "../../"

  customer_id           = "00000000-0000-0000-0000-000000000000"
  organization_id       = "123456789012"
  vendor_aws_account_id = "111122223333"

  # The regions where you actively deploy workloads. This scopes what the
  # B.O.R.I.S memory scrape retains; it does not restrict what B.O.R.I.S reads.
  # Editing this list re-registers on the next apply.
  active_regions = ["europe-west4", "us-east1"]

  # Reuse an existing project rather than creating one.
  create_project = false
  project_id     = "my-existing-boris-host"

  # Register from inside apply instead of running the curl by hand. Transient
  # failures retry with backoff; a rejected credential or a conflicting
  # registration fails immediately rather than retrying.
  enable_self_registration = true
  registration_endpoint    = "https://install.getboris.ai"
  connection_secret        = var.connection_secret

  # Optional hardening: also block reading compute instance metadata, which
  # roles/viewer would otherwise allow and the default deny list does not cover.
  additional_denied_permissions = [
    "compute.googleapis.com/instances.get",
  ]
}

output "organization_id" {
  description = "Registered GCP organization ID."
  value       = module.boris_gcp.organization_id
}

output "service_account_email" {
  description = "Service account B.O.R.I.S impersonates."
  value       = module.boris_gcp.service_account_email
}
