# general terraform settings
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# variables
variable "project_id" {
  type        = string
  description = "RNS DevOps Task"
  default     = "deft-stratum-447710-h0"
}

variable "region" {
  type        = string
  description = "US region"
  default     = "us-central1"
}

variable "instance_name" {
  type        = string
  description = "DB resource that will be created now"
  default     = "my-postgres-db"
}

variable "db_password" {
  type        = string
  description = "password for DB user"
  default     = "mypassword"
  sensitive   = true
}

# to create Postgres sql cloud instance on GCP
resource "google_sql_database_instance" "postgres_instance" {
  name             = var.instance_name
  database_version = "POSTGRES_14"
  region           = var.region

  settings {
    tier = "db-f1-micro"
  }

  deletion_protection = false
}

# To create a default Postgres user
resource "google_sql_user" "postgres_user" {
  name     = "postgres"
  instance = google_sql_database_instance.postgres_instance.name
  password = var.db_password
}

# To create a logical database
resource "google_sql_database" "my_database" {
  name     = "mydb"
  instance = google_sql_database_instance.postgres_instance.name
}

# To deploy a CloudRun service
resource "google_cloud_run_service" "my_service" {
  name     = "my-cloud-run-service"
  location = var.region

  metadata {
    annotations = {
      "run.googleapis.com/ingress" = "all"
    }
  }

  template {
    spec {
      containers {
        # A basic Hello world Container Image from Artifact Registry
        image = "us-docker.pkg.dev/cloudrun/container/hello"
        
        # env variables for container
        env {
          name  = "DB_HOST"
          value = google_sql_database_instance.postgres_instance.connection_name
        }
        env {
          name  = "DB_USER"
          value = google_sql_user.postgres_user.name
        }
        env {
          name  = "DB_PASS"
          value = google_sql_user.postgres_user.password
        }
      }
    }
  }

  # To make sure all traffic is sent to updated / latest revisions
  traffic {
    percent         = 100
    latest_revision = true
  }

  # To differentiate between changes, generate a revision name automatically 
  autogenerate_revision_name = true
}

# To enable public access to CloudRun service
resource "google_cloud_run_service_iam_member" "public_invoker" {
  location = google_cloud_run_service.my_service.location
  project  = var.project_id
  service  = google_cloud_run_service.my_service.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Load balancer for CloudRun
# 1. Serverless NEG (Network Endpoint Group) to link CloudRun service to the Load Balancer 
resource "google_compute_region_network_endpoint_group" "cloud_run_neg" {
  name                  = "cloud-run-neg"
  project               = var.project_id
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_service.my_service.name
  }
}

# 2. Backend Service referencing the NEG
resource "google_compute_backend_service" "cloud_run_backend" {
  name        = "cloud-run-backend"
  project     = var.project_id
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 30

  backend {
    group = google_compute_region_network_endpoint_group.cloud_run_neg.id
  }
}

# 3. URL Mapping to map incoming requests to the backend service
resource "google_compute_url_map" "cloud_run_url_map" {
  name            = "cloud-run-url-map"
  project         = var.project_id
  default_service = google_compute_backend_service.cloud_run_backend.self_link
}

# 4. Target HTTP Proxy to forward incoming requests from the url map to the correct backend
resource "google_compute_target_http_proxy" "cloud_run_http_proxy" {
  name    = "cloud-run-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.cloud_run_url_map.self_link
}

# 5. Global Forwarding Rule (HTTP on port 80). Main entry point for all traffic to the load balancer that will be passed to the target http proxy
resource "google_compute_global_forwarding_rule" "cloud_run_forwarding_rule" {
  name                  = "cloud-run-forwarding-rule"
  project               = var.project_id
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_target_http_proxy.cloud_run_http_proxy.self_link
  load_balancing_scheme = "EXTERNAL"
}