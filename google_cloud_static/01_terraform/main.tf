variable "project" {
  type    = string
  default = "pioneering-axe-306118"
}

variable "region" {
  type    = string
  default = "europe-west3"
}

variable "zone" {
  type    = string
  default = "europe-west3-a"
}

variable "number_of_control_plane_nodes" {
  type    = number
  default = 3
}

variable "number_of_worker_nodes" {
  type    = number
  default = 1
}

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "3.5.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
}

#
# NETWORK
#

resource "google_compute_network" "network" {
  name                    = "kubernetes-the-hard-way"
  auto_create_subnetworks = "false"
}

resource "google_compute_subnetwork" "nodes_subnet" {
  name          = "kubernetes"
  ip_cidr_range = "10.240.0.0/24"
  network       = google_compute_network.network.self_link
}

resource "google_compute_firewall" "allow_internal" {
  name    = "kubernetes-the-hard-way-allow-internal"
  network = google_compute_network.network.name

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.240.0.0/24", "10.200.0.0/16"]
}

resource "google_compute_firewall" "allow_external" {
  name    = "kubernetes-the-hard-way-allow-external"
  network = google_compute_network.network.self_link

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["0.0.0.0/0"]
}

#
# COMPUTE INSTANCES
#

resource "google_compute_instance" "controller" {
  count          = var.number_of_control_plane_nodes
  name           = "controller-${count.index}"
  tags           = ["kubernetes-the-hard-way", "controller"]
  machine_type   = "e2-standard-2"
  can_ip_forward = true

  boot_disk {
    initialize_params {
      size  = 200
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    network    = google_compute_network.network.self_link
    subnetwork = google_compute_subnetwork.nodes_subnet.self_link
    network_ip = format("10.240.0.1%02d", count.index)
    access_config {
    }
  }

  service_account {
    scopes = ["compute-rw", "storage-ro", "service-management", "service-control", "logging-write", "monitoring"]
  }
}

resource "google_compute_instance" "worker" {
  count          = var.number_of_worker_nodes
  name           = "worker-${count.index}"
  tags           = ["kubernetes-the-hard-way", "worker"]
  machine_type   = "e2-standard-2"
  can_ip_forward = true

  boot_disk {
    initialize_params {
      size  = 200
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
    }
  }

  network_interface {
    network    = google_compute_network.network.self_link
    subnetwork = google_compute_subnetwork.nodes_subnet.self_link
    network_ip = format("10.240.0.2%02d", count.index)
    access_config {
    }
  }

  metadata = {
    pod-cidr = "10.200.${count.index}.0/24"
  }

  service_account {
    scopes = ["compute-rw", "storage-ro", "service-management", "service-control", "logging-write", "monitoring"]
  }
}

#
# LOAD BALANCER
#

resource "google_compute_address" "ip_address" {
  name = "kubernetes-the-hard-way"
}

resource "google_compute_http_health_check" "health_check" {
  name         = "kubernetes"
  description  = "Kubernetes Health Check"
  host         = "kubernetes.default.svc.cluster.local"
  port         = 80
  request_path = "/healthz"
}

resource "google_compute_firewall" "allow_health_check" {
  name    = "kubernetes-the-hard-way-allow-health-check"
  network = google_compute_network.network.self_link

  allow {
    protocol = "tcp"
  }

  source_ranges = ["209.85.152.0/22", "209.85.204.0/22", "35.191.0.0/16"]
}

resource "google_compute_target_pool" "target_pool" {
  name      = "kubernetes-target-pool"
  instances = google_compute_instance.controller[*].self_link

  health_checks = [
    google_compute_http_health_check.health_check.self_link,
  ]
}

#
# NETWORK ROUTES TO POD SUBNETS
#

resource "google_compute_route" "pod_subnet_route" {
  count             = var.number_of_worker_nodes
  name              = "kubernetes-route-10-200-${count.index}-0-24"
  dest_range        = "10.200.${count.index}.0/24"
  network           = google_compute_network.network.self_link
  next_hop_instance = google_compute_instance.worker[count.index].self_link
}
