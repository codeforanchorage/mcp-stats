variable "aws_region" {
  description = "AWS region the MCP fleet runs in. Every MCP is deployed in this one account/region."
  type        = string
  default     = "us-west-2"
}

variable "project_tag" {
  description = <<-EOT
    Tag VALUE used to discover MCP log groups via the Resource Groups Tagging
    API. Every MCP repo tags both its Lambda log group and its API Gateway
    access log group with `Project = <this value>`. Changing this only makes
    sense if the fleet-wide tag convention changes.
  EOT
  type        = string
  default     = "mcp-server"
}

variable "dashboard_name" {
  description = "Name of the account-wide CloudWatch dashboard this project creates."
  type        = string
  default     = "mcp-fleet-usage"
}

variable "environment" {
  description = <<-EOT
    Deployment environment to scope the dashboard to. MCP log groups are named
    `/aws/lambda/<mcp>-<env>` and `/aws/apigateway/<mcp>-<env>-access`, and the
    fleet runs both staging and prod under the same `Project` tag. Discovery
    keeps only the groups whose name matches this environment.

    Set to "" to include EVERY discovered environment (staging + prod commingled).
  EOT
  type        = string
  default     = "prod"
}
