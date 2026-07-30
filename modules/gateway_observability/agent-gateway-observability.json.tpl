{
  "displayName": "Agent Gateway Observability",
  "description": "Gateway egress blocked/allowed and Model Armor blocked/allowed (agentic-ai-lens).",
  "labels": {},
  "dashboardFilters": [
    {
      "filterType": "VALUE_ONLY",
      "labelKey": "",
      "templateVariable": "agent_identity",
      "timeSeriesQuery": {
        "opsAnalyticsQuery": {
          "savedQueryId": "",
          "sql": "SELECT REGEXP_EXTRACT(proto_payload.audit_log.authentication_info.principal_subject, r'([^/]+)$') AS reasoning_engine_id FROM `${project_id}.global._Default._AllLogs` WHERE proto_payload.audit_log.service_name = 'iap.googleapis.com' AND proto_payload.audit_log.authentication_info.principal_subject LIKE '%/reasoningEngines/%' GROUP BY reasoning_engine_id"
        },
        "outputFullDuration": false,
        "unitOverride": ""
      },
      "valueType": "STRING"
    },
    {
      "filterType": "VALUE_ONLY",
      "labelKey": "",
      "templateVariable": "gateway",
      "timeSeriesQuery": {
        "opsAnalyticsQuery": {
          "savedQueryId": "",
          "sql": "SELECT REGEXP_EXTRACT(JSON_VALUE(resource.labels.gateway_name), r'([^/]+)$') AS gateway_name FROM `${project_id}.global._Default._AllLogs` WHERE resource.type = 'networkservices.googleapis.com/Gateway' AND JSON_VALUE(resource.labels.gateway_name) IS NOT NULL GROUP BY gateway_name"
        },
        "outputFullDuration": false,
        "unitOverride": ""
      },
      "valueType": "STRING"
    },
    {
      "filterType": "VALUE_ONLY",
      "labelKey": "",
      "templateVariable": "region",
      "timeSeriesQuery": {
        "opsAnalyticsQuery": {
          "savedQueryId": "",
          "sql": "SELECT JSON_VALUE(resource.labels.location) AS location FROM `${project_id}.global._Default._AllLogs` WHERE resource.type = 'networkservices.googleapis.com/Gateway' AND JSON_VALUE(resource.labels.location) IS NOT NULL GROUP BY location"
        },
        "outputFullDuration": false,
        "unitOverride": ""
      },
      "valueType": "STRING"
    },
    {
      "filterType": "VALUE_ONLY",
      "labelKey": "",
      "templateVariable": "destination",
      "timeSeriesQuery": {
        "opsAnalyticsQuery": {
          "savedQueryId": "",
          "sql": "SELECT JSON_VALUE(json_payload.tlsSniHostname) AS host FROM `${project_id}.global._Default._AllLogs` WHERE resource.type = 'networkservices.googleapis.com/Gateway' AND JSON_VALUE(json_payload.tlsSniHostname) IS NOT NULL GROUP BY host"
        },
        "outputFullDuration": false,
        "unitOverride": ""
      },
      "valueType": "STRING"
    }
  ],
  "mosaicLayout": {
    "columns": 48,
    "tiles": [
      {
        "xPos": 0,
        "yPos": 0,
        "height": 18,
        "width": 24,
        "widget": {
          "title": "Gateway egress: blocked (per 15 min)",
          "xyChart": {
            "chartOptions": {
              "mode": "COLOR"
            },
            "dataSets": [
              {
                "plotType": "STACKED_BAR",
                "targetAxis": "Y1",
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"logging.googleapis.com/user/lens_gateway_egress_blocked\" resource.type=\"networkservices.googleapis.com/Gateway\"",
                    "aggregation": {
                      "alignmentPeriod": "900s",
                      "perSeriesAligner": "ALIGN_DELTA",
                      "crossSeriesReducer": "REDUCE_SUM",
                      "groupByFields": []
                    }
                  }
                }
              }
            ],
            "yAxis": {
              "label": "Blocked",
              "scale": "LINEAR"
            }
          }
        }
      },
      {
        "xPos": 24,
        "yPos": 0,
        "height": 18,
        "width": 24,
        "widget": {
          "title": "Gateway egress: allowed (per 15 min)",
          "xyChart": {
            "chartOptions": {
              "mode": "COLOR"
            },
            "dataSets": [
              {
                "plotType": "STACKED_BAR",
                "targetAxis": "Y1",
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"logging.googleapis.com/user/lens_gateway_egress_allowed\" resource.type=\"networkservices.googleapis.com/Gateway\"",
                    "aggregation": {
                      "alignmentPeriod": "900s",
                      "perSeriesAligner": "ALIGN_DELTA",
                      "crossSeriesReducer": "REDUCE_SUM",
                      "groupByFields": []
                    }
                  }
                }
              }
            ],
            "yAxis": {
              "label": "Allowed",
              "scale": "LINEAR"
            }
          }
        }
      },
      {
        "xPos": 0,
        "yPos": 18,
        "height": 16,
        "width": 24,
        "widget": {
          "title": "Gateway egress: blocked log events",
          "logsPanel": {
            "filter": "resource.type=\"networkservices.googleapis.com/Gateway\"\nhttpRequest.requestMethod!=\"CONNECT\"\njsonPayload.authzPolicyInfo.result=\"DENIED\"",
            "resourceNames": [
              "projects/${project_id}"
            ]
          }
        }
      },
      {
        "xPos": 24,
        "yPos": 18,
        "height": 16,
        "width": 24,
        "widget": {
          "title": "Gateway egress: allowed log events",
          "logsPanel": {
            "filter": "resource.type=\"networkservices.googleapis.com/Gateway\"\nhttpRequest.requestMethod!=\"CONNECT\"\njsonPayload.authzPolicyInfo.result=\"ALLOWED\"",
            "resourceNames": [
              "projects/${project_id}"
            ]
          }
        }
      },
      {
        "xPos": 0,
        "yPos": 34,
        "height": 18,
        "width": 24,
        "widget": {
          "title": "Model Armor: blocked (per 15 min)",
          "xyChart": {
            "chartOptions": {
              "mode": "COLOR"
            },
            "dataSets": [
              {
                "plotType": "STACKED_BAR",
                "targetAxis": "Y1",
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"logging.googleapis.com/user/lens_model_armor_blocked\" resource.type=\"modelarmor.googleapis.com/SanitizeOperation\"",
                    "aggregation": {
                      "alignmentPeriod": "900s",
                      "perSeriesAligner": "ALIGN_DELTA",
                      "crossSeriesReducer": "REDUCE_SUM",
                      "groupByFields": []
                    }
                  }
                }
              }
            ],
            "yAxis": {
              "label": "Blocked",
              "scale": "LINEAR"
            }
          }
        }
      },
      {
        "xPos": 24,
        "yPos": 34,
        "height": 18,
        "width": 24,
        "widget": {
          "title": "Model Armor: allowed (per 15 min)",
          "xyChart": {
            "chartOptions": {
              "mode": "COLOR"
            },
            "dataSets": [
              {
                "plotType": "STACKED_BAR",
                "targetAxis": "Y1",
                "timeSeriesQuery": {
                  "timeSeriesFilter": {
                    "filter": "metric.type=\"logging.googleapis.com/user/lens_model_armor_allowed\" resource.type=\"modelarmor.googleapis.com/SanitizeOperation\"",
                    "aggregation": {
                      "alignmentPeriod": "900s",
                      "perSeriesAligner": "ALIGN_DELTA",
                      "crossSeriesReducer": "REDUCE_SUM",
                      "groupByFields": []
                    }
                  }
                }
              }
            ],
            "yAxis": {
              "label": "Allowed",
              "scale": "LINEAR"
            }
          }
        }
      },
      {
        "xPos": 0,
        "yPos": 52,
        "height": 16,
        "width": 24,
        "widget": {
          "title": "Model Armor: blocked log events",
          "logsPanel": {
            "filter": "resource.type=\"modelarmor.googleapis.com/SanitizeOperation\"\njsonPayload.sanitizationResult.sanitizationVerdict=\"MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK\"",
            "resourceNames": [
              "projects/${project_id}"
            ]
          }
        }
      },
      {
        "xPos": 24,
        "yPos": 52,
        "height": 16,
        "width": 24,
        "widget": {
          "title": "Model Armor: allowed log events",
          "logsPanel": {
            "filter": "resource.type=\"modelarmor.googleapis.com/SanitizeOperation\"\njsonPayload.sanitizationResult.sanitizationVerdict=\"MODEL_ARMOR_SANITIZATION_VERDICT_ALLOW\"",
            "resourceNames": [
              "projects/${project_id}"
            ]
          }
        }
      },
      {
        "xPos": 0,
        "yPos": 68,
        "height": 20,
        "width": 48,
        "widget": {
          "title": "Traffic overview & IAP enforcement mode",
          "timeSeriesTable": {
            "columnSettings": [],
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "opsAnalyticsQuery": {
                    "sql": "WITH iap_logs AS (\n  SELECT\n    proto_payload.audit_log.request_metadata.request_attributes.host AS host,\n    REGEXP_EXTRACT(proto_payload.audit_log.authentication_info.principal_subject, r'([^/]+)$') AS reasoning_engine_id,\n    REGEXP_EXTRACT(auth.resource, r'agentRegistry/((?:endpoints|mcpServers|agents)/[^/]+)') AS short_resource,\n    IFNULL(auth.granted, FALSE) AS iap_is_authorized,\n    JSON_VALUE(proto_payload.audit_log.metadata, '$.dryRun') = 'true' AS iap_dry_run,\n    COUNT(*) AS iap_log_count\n  FROM `${project_id}.global._Default._AllLogs`, UNNEST(proto_payload.audit_log.authorization_info) AS auth\n  WHERE proto_payload.audit_log.service_name = \"iap.googleapis.com\"\n    AND proto_payload.audit_log.request_metadata.request_attributes.host IS NOT NULL\n  GROUP BY 1, 2, 3, 4, 5\n),\ngw_logs AS (\n  SELECT\n    JSON_VALUE(json_payload.tlsSniHostname) AS host,\n    REGEXP_EXTRACT(JSON_VALUE(resource.labels.gateway_name), r'([^/]+)$') AS gateway_name,\n    JSON_VALUE(resource.labels.location) AS location,\n    REGEXP_EXTRACT(JSON_VALUE(json_payload.agentGatewayInfo.agentRegistryResource), r'((?:endpoints|mcpServers|agents)/[^/]+)') AS short_resource,\n    JSON_VALUE(json_payload.authzPolicyInfo.result) = 'ALLOWED' AS gw_is_authorized,\n    COUNT(*) AS gw_log_count\n  FROM `${project_id}.global._Default._AllLogs`\n  WHERE resource.type = \"networkservices.googleapis.com/Gateway\"\n    AND JSON_VALUE(json_payload.tlsSniHostname) IS NOT NULL\n    AND http_request.request_method != 'CONNECT'\n  GROUP BY 1, 2, 3, 4, 5\n),\njoined_logs AS (\n  SELECT\n    COALESCE(i.host, g.host) AS host,\n    i.reasoning_engine_id,\n    g.gateway_name,\n    g.location,\n    COALESCE(i.short_resource, g.short_resource) AS short_resource,\n    i.iap_is_authorized,\n    g.gw_is_authorized,\n    i.iap_dry_run,\n    IFNULL(i.iap_log_count, 0) AS iap_log_count,\n    IFNULL(g.gw_log_count, 0) AS gw_log_count\n  FROM iap_logs i\n  FULL OUTER JOIN gw_logs g\n    ON i.host = g.host AND IFNULL(i.short_resource, '') = IFNULL(g.short_resource, '')\n)\nSELECT host, reasoning_engine_id, gateway_name, short_resource, gw_is_authorized, iap_is_authorized, iap_dry_run, iap_log_count, gw_log_count\nFROM joined_logs\nWHERE IF(@agent_identity = \"*\", TRUE, reasoning_engine_id = @agent_identity)\n  AND IF(@gateway = \"*\", TRUE, gateway_name = @gateway)\n  AND IF(@region = \"*\", TRUE, location = @region)\n  AND IF(@destination = \"*\", TRUE, host = @destination)\nORDER BY (iap_log_count + gw_log_count) DESC"
                  }
                }
              }
            ],
            "metricVisualization": "NUMBER"
          }
        }
      },
      {
        "xPos": 0,
        "yPos": 90,
        "height": 16,
        "width": 48,
        "widget": {
          "title": "GCP API IAM denials",
          "timeSeriesTable": {
            "columnSettings": [],
            "dataSets": [
              {
                "timeSeriesQuery": {
                  "opsAnalyticsQuery": {
                    "sql": "SELECT\n  REGEXP_EXTRACT(proto_payload.audit_log.authentication_info.principal_subject, r'([^/]+)$') AS reasoning_engine_id,\n  proto_payload.audit_log.service_name,\n  proto_payload.audit_log.method_name,\n  auth.permission,\n  COUNT(*) AS log_count\nFROM `${project_id}.global._Default._AllLogs`, UNNEST(proto_payload.audit_log.authorization_info) AS auth\nWHERE log_name LIKE '%cloudaudit.googleapis.com%'\n  AND IFNULL(auth.granted, false) = false\n  AND proto_payload.audit_log.authentication_info.principal_subject LIKE '%/reasoningEngines/%'\n  AND IF(@agent_identity = \"*\", TRUE, REGEXP_EXTRACT(proto_payload.audit_log.authentication_info.principal_subject, r'([^/]+)$') = @agent_identity)\nGROUP BY 1, 2, 3, 4\nORDER BY log_count DESC"
                  }
                }
              }
            ],
            "metricVisualization": "NUMBER"
          }
        }
      }
    ]
  }
}