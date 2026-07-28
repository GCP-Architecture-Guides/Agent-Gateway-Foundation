locals {
  llm_usage_filter = <<-EOT
    resource.type="aiplatform.googleapis.com/ReasoningEngine"
    jsonPayload.event="llm_usage"
  EOT

  llm_usage_label_extractors = {
    agent_id   = "EXTRACT(jsonPayload.agent_id)"
    department = "EXTRACT(jsonPayload.department)"
    model      = "EXTRACT(jsonPayload.model)"
    agent_role = "EXTRACT(jsonPayload.agent_role)"
  }
}

resource "google_logging_metric" "llm_total_tokens" {
  project = var.project_id
  name    = "lens_llm_total_tokens"
  filter  = local.llm_usage_filter

  value_extractor  = "EXTRACT(jsonPayload.total_tokens)"
  label_extractors = local.llm_usage_label_extractors

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 64
      growth_factor      = 2
      scale              = 1
    }
  }

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
    labels {
      key        = "agent_id"
      value_type = "STRING"
    }
    labels {
      key        = "department"
      value_type = "STRING"
    }
    labels {
      key        = "model"
      value_type = "STRING"
    }
    labels {
      key        = "agent_role"
      value_type = "STRING"
    }
  }
}

resource "google_logging_metric" "llm_prompt_tokens" {
  project = var.project_id
  name    = "lens_llm_prompt_tokens"
  filter  = local.llm_usage_filter

  value_extractor  = "EXTRACT(jsonPayload.prompt_tokens)"
  label_extractors = local.llm_usage_label_extractors

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 64
      growth_factor      = 2
      scale              = 1
    }
  }

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
    labels {
      key        = "agent_id"
      value_type = "STRING"
    }
    labels {
      key        = "department"
      value_type = "STRING"
    }
    labels {
      key        = "model"
      value_type = "STRING"
    }
    labels {
      key        = "agent_role"
      value_type = "STRING"
    }
  }
}

resource "google_logging_metric" "llm_output_tokens" {
  project = var.project_id
  name    = "lens_llm_output_tokens"
  filter  = local.llm_usage_filter

  value_extractor  = "EXTRACT(jsonPayload.output_tokens)"
  label_extractors = local.llm_usage_label_extractors

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 64
      growth_factor      = 2
      scale              = 1
    }
  }

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "1"
    labels {
      key        = "agent_id"
      value_type = "STRING"
    }
    labels {
      key        = "department"
      value_type = "STRING"
    }
    labels {
      key        = "model"
      value_type = "STRING"
    }
    labels {
      key        = "agent_role"
      value_type = "STRING"
    }
  }
}

resource "google_logging_metric" "llm_call_count" {
  project = var.project_id
  name    = "lens_llm_call_count"
  filter  = local.llm_usage_filter

  label_extractors = local.llm_usage_label_extractors

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key        = "agent_id"
      value_type = "STRING"
    }
    labels {
      key        = "department"
      value_type = "STRING"
    }
    labels {
      key        = "model"
      value_type = "STRING"
    }
    labels {
      key        = "agent_role"
      value_type = "STRING"
    }
  }
}

resource "google_logging_metric" "llm_error_count" {
  project = var.project_id
  name    = "lens_llm_error_count"
  filter  = "${local.llm_usage_filter}\n(jsonPayload.status!=\"ok\" OR severity=\"ERROR\")"

  label_extractors = local.llm_usage_label_extractors

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key        = "agent_id"
      value_type = "STRING"
    }
    labels {
      key        = "department"
      value_type = "STRING"
    }
    labels {
      key        = "model"
      value_type = "STRING"
    }
    labels {
      key        = "agent_role"
      value_type = "STRING"
    }
  }
}
