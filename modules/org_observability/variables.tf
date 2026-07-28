variable "metrics_scope_project_id" {
  description = "Hub GCP project that owns the metrics scope and org dashboard."
  type        = string
}

variable "monitored_project_ids" {
  description = "Additional GCP projects to add to the hub metrics scope (hub project is always in scope)."
  type        = list(string)
  default     = []
}

variable "scope_project_agent_dashboard_id" {
  description = "Cloud Monitoring dashboard id for Agent Observability in the scope (hub) project."
  type        = string
  default     = ""
}

variable "scope_project_gateway_dashboard_id" {
  description = "Cloud Monitoring dashboard id for Agent Gateway Observability in the scope (hub) project."
  type        = string
  default     = ""
}
