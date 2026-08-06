# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This code is for PoC environment only.
# This demo code is not built for production workload.

# ------------------------------------------------------------------------------
# 2. CORE INFRASTRUCTURE & NETWORKING
# ------------------------------------------------------------------------------
# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

# Interface Subnet for Network Attachment
resource "google_compute_subnetwork" "intf_subnet" {
  name                     = "${var.prefix}-intf-subnet"
  ip_cidr_range            = "192.168.10.0/28"
  region                   = var.location
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}
# SGP Subnet for Network Attachment
resource "google_compute_subnetwork" "sgp_subnet" {
  name                     = "${var.prefix}-sgp-subnet"
  ip_cidr_range            = "10.10.10.0/24"
  region                   = var.location
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Network Attachment for Egress Gateway
resource "google_compute_network_attachment" "psc_network_attachment" {
  name                  = "${var.prefix}-psc-network-attachment"
  region                = var.location
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [google_compute_subnetwork.intf_subnet.id]
}

# ==============================================================================
# GAP 5 (from official docs): PSC Ingress Firewall Rule
# ==============================================================================
# Official docs (set-up-vpc-connectivity) require a firewall rule allowing
# ingress from the PSC network attachment subnet into internal services / MCP
# servers hosted in the VPC. Without this, PSC traffic from the gateway is
# blocked by the implicit deny-all ingress rule.
#
# Disabled by default (enable_psc_firewall_rule = false) so existing deployments
# are not affected. Enable in terraform.tfvars when teams host internal
# services (MCP servers, private APIs) inside the VPC that agents call outbound.
# ==============================================================================
resource "google_compute_firewall" "psc_ingress_allow" {
  count   = var.enable_psc_firewall_rule ? 1 : 0
  name    = "${var.prefix}-psc-ingress-allow"
  network = google_compute_network.vpc.name
  project = var.project_id

  description = "Allow PSC ingress from gateway network attachment subnet to internal services/MCP servers."
  direction   = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["443", "80"]
  }

  # Source: the PSC interface subnet where the gateway attaches
  source_ranges = [google_compute_subnetwork.intf_subnet.ip_cidr_range]

  depends_on = [google_project_service.compute]
}

# ==============================================================================
# PSC Egress VIP — Allow traffic to 240.0.0.0/4 (Class E, GCP PSC gateway VIPs)
# ==============================================================================
# GCP uses the Class E address range (240.0.0.0/4) for PSC egress gateway VIPs.
# When an RE container makes an outbound HTTP call, the PSC network attachment
# intercepts it and redirects the packet to the egress gateway's VIP — typically
# 240.0.0.2. Without an explicit VPC egress firewall rule allowing this range,
# the GCP implicit deny-all egress rule drops the packet before it ever reaches
# the gateway, causing silent connection failures that look identical to
# "host not in egress allowlist" errors but are actually firewall drops.
#
# Symptom: agents work locally but ALL egress calls fail after deployment,
# even for hosts that are correctly registered in allowed_egress_hosts.
# Cloud Logging shows no gateway logs — the packet never reaches the SWP.
#
# This rule is always enabled (not gated by a variable) because:
#   1. It is required for the PSC egress to function at all
#   2. 240.0.0.0/4 is not routable on the public internet — it can only resolve
#      to internal GCP PSC VIPs, so there is no security risk in allowing it
#   3. Not having it is a guaranteed post-deployment headache on every new project
# ==============================================================================
resource "google_compute_firewall" "psc_egress_vip_allow" {
  name    = "${var.prefix}-psc-egress-vip-allow"
  network = google_compute_network.vpc.name
  project = var.project_id

  description = "Allow egress to 240.0.0.0/4 (GCP PSC gateway Class E VIP range, e.g. 240.0.0.2). Required for PSC egress interception to reach the Agent Gateway SWP."
  direction   = "EGRESS"
  priority    = 900

  allow {
    protocol = "tcp"
    ports    = ["443", "80"]
  }

  destination_ranges = ["240.0.0.0/4"]

  depends_on = [google_project_service.compute]
}

# Agent Gateway - Ingress
resource "google_network_services_agent_gateway" "ingress_gateway" {
  provider = google-beta
  name     = "${var.prefix}-ingress-gateway"
  location = var.location
  # protocols is deprecated (removed in a future provider major release);
  # governed_access_path already encodes the gateway direction.
  google_managed {
    governed_access_path = "CLIENT_TO_AGENT"
  }

  # Wire gateway to Agent Registry so it can reference registered services.
  # Format: //agentregistry.googleapis.com/projects/{project}/locations/{region}
  registries = [
    "//agentregistry.googleapis.com/projects/${var.project_id}/locations/${var.location}"
  ]

  depends_on = [google_project_service.networkservices, google_project_service.agentregistry]
}

# Agent Gateway - Egress
resource "google_network_services_agent_gateway" "egress_gateway" {
  provider = google-beta
  name     = "${var.prefix}-egress-gateway"
  location = var.location
  # protocols is deprecated (removed in a future provider major release);
  # governed_access_path already encodes the gateway direction.
  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }

  # Wire gateway to Agent Registry — gateway enforces routes only to
  # services registered under this project+location registry.
  registries = [
    "//agentregistry.googleapis.com/projects/${var.project_id}/locations/${var.location}"
  ]

  network_config {
    egress {
      network_attachment = google_compute_network_attachment.psc_network_attachment.id
    }
    dns_peering_config {
      target_project = var.project_id
      target_network = google_compute_network.vpc.id
      domains        = ["sgp.internal.gemini-corp."]
    }
  }

  depends_on = [google_project_service.networkservices, google_project_service.agentregistry]
}

# =========================================================================
# SEMANTIC GOVERNANCE POLICY (SGP) — VPC CONNECTIVITY
# =========================================================================
# --- 1. SGP Network Attachment ---
resource "google_compute_network_attachment" "sgp_network_attachment" {
  name                  = "${var.prefix}-sgp-nw-attachment"
  region                = var.location
  description           = "Network attachment for SGP engine PSC connectivity"
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [google_compute_subnetwork.intf_subnet.id]

  depends_on = [google_project_service.compute]
}

# --- 2. Static Internal IP for PSC Endpoint ---
resource "google_compute_address" "sgp_psc_ip" {
  name         = "${var.prefix}-sgp-psc-ip"
  region       = var.location
  subnetwork   = google_compute_subnetwork.sgp_subnet.id
  address_type = "INTERNAL"
  description  = "Static internal IP for SGP PSC forwarding rule endpoint"

  depends_on = [google_project_service.compute]
}

# --- 3. PSC Forwarding Rule → SGP Engine Service Attachment ---
resource "google_compute_forwarding_rule" "sgp_psc_endpoint" {
  name                  = "${var.prefix}-sgp-psc-endpoint"
  region                = var.location
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.sgp_subnet.id
  ip_address            = google_compute_address.sgp_psc_ip.id
  load_balancing_scheme = ""
  target                = data.external.sgp_engine.result.psc_service_attachment
  description           = "PSC endpoint connecting our VPC to the automated SGP policy engine"

  depends_on = [
    google_compute_address.sgp_psc_ip,
    google_project_service.compute,
  ]
}

# --- 4. Private DNS Zone + A Record for SGP Hostname ---
# Note: Since the variable is removed, we just hardcode the local default
resource "google_dns_managed_zone" "sgp_dns_zone" {
  name        = "${var.prefix}-sgp-dns-zone"
  dns_name    = "sgp.internal.gemini-corp."
  description = "Private DNS zone for SGP engine hostname resolution"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }

  depends_on = [google_project_service.dns]
}

resource "google_dns_record_set" "sgp_a_record" {
  name         = "sgp.internal.gemini-corp."
  managed_zone = google_dns_managed_zone.sgp_dns_zone.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.sgp_psc_ip.address]

  depends_on = [
    google_dns_managed_zone.sgp_dns_zone,
    google_compute_address.sgp_psc_ip,
  ]
}



