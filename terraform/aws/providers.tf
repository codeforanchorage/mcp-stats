provider "aws" {
  region = var.aws_region
}

# Used only to build the dashboard console URL in outputs.tf.
data "aws_caller_identity" "current" {}
