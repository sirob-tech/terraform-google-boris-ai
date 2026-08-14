# Provider and Terraform version constraints for the B.O.R.I.S GCP onboarding
# module. The module is applied directly by the customer's GCP org admin; the
# Google credentials come from their environment (gcloud ADC / impersonation).
#
# required_version is >= 1.9.0 because several variable `validation` blocks
# reference other input variables (cross-variable validation), which Terraform
# only supports from 1.9 onward.
#
# The google floor is >= 5.41.0, which is where google_project gained the
# deletion_policy argument used in project.tf. Anything older fails at
# `terraform validate` with "An argument named deletion_policy is not expected
# here", pointing at a line the customer did not write — so the floor is a real
# constraint, not a conservative guess. google_iam_deny_policy and the provider
# attribute_condition are both older than that and impose no higher floor.
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.41.0"
    }
  }
}
