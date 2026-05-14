terraform {
  # >= 1.2 for resource `lifecycle.precondition` (used in dashboard.tf).
  required_version = ">= 1.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
