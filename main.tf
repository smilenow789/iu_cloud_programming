#
# Deploy info:
# 1. GCP Projekt erstellen: https://console.cloud.google.com/projectcreate
# 2. project ID des erstellten Projekts notieren
# 3. Projekt mit einem Rechnungskonto verknüpfen
# 4. Google Cloud CLI installieren & einloggen https://cloud.google.com/sdk/docs/install-sdk?hl=de: 
#    - gcloud auth login
#    - gcloud auth application-default login
#    - gcloud config set project <PROJECT_ID>
#    - gcloud auth application-default set-quota-project <Project-ID>
# 5. Notwendige Dateien sicherstellen:
#    - Ordner "backend/" existiert und enthält Dockerfile + Source Code
#    - Datei "firestore.rules" existiert im Root-Verzeichnis
#    - Datei "storage.rules" existiert im Root-Verzeichnis
# 6. Datei terraform.tfvars erstellen und Variablen definieren:
#    - project_id           = "..."
#    - android_package_name = "..."
#    - android_sha1_hashes  = ["..."]
# 7. Terminal im Ordner öffnen
# 8. Umgebungsvariable in der Powershell setzen $env:GOOGLE_CLOUD_QUOTA_PROJECT = "<Projekt-ID>"
# 8. "terraform init" ausführen
# 9. "terraform apply" ausführen
#


# -----------------------------------------------------------------------------------------
# SETUP & PROVIDERS
# -----------------------------------------------------------------------------------------
terraform {
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 5.0" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.0" }
    local       = { source = "hashicorp/local", version = "~> 2.0" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}


# -----------------------------------------------------------------------------------------
# 1. APIs AKTIVIEREN & WARTEN
# -----------------------------------------------------------------------------------------
# Aktiviert zuerst die Management-APIs
resource "google_project_service" "core_apis" {
  project = var.project_id
  for_each = toset([
    "cloudresourcemanager.googleapis.com", # IAM Änderungen
    "serviceusage.googleapis.com",         # Terraform APIs aktivieren darf
  ])
  service            = each.key
  disable_on_destroy = false
}


resource "time_sleep" "wait_for_core_apis" {
  depends_on      = [google_project_service.core_apis]
  create_duration = "60s"
}


# Aktiviert die restlichen notwendigen Dienste
resource "google_project_service" "apis" {
  project = var.project_id
  for_each = toset([
    "iam.googleapis.com",                  # Rechteverwaltung
    "identitytoolkit.googleapis.com",      # Authentication 
    "cloudbuild.googleapis.com",           # Container Build
    "artifactregistry.googleapis.com",     # Docker Images
    "run.googleapis.com",                  # Cloud Run
    "storage.googleapis.com",              # Storage für PDF Uploads
    "firebasestorage.googleapis.com",      # Firebase Storage Link
    "aiplatform.googleapis.com",           # Vertex AI (Gemini)
    "firebase.googleapis.com",             # Firebase Core
    "firebaserules.googleapis.com",        # Security Rules
    "firestore.googleapis.com",            # Datenbank
  ])
  service            = each.key
  disable_on_destroy = false

  depends_on = [time_sleep.wait_for_core_apis]
}

# Wartezeit zur Aktivierung der APIs
resource "time_sleep" "wait_60_seconds" {
  depends_on      = [google_project_service.apis]
  create_duration = "60s"
}

# -----------------------------------------------------------------------------------------
# 2. IDENTITÄT (SERVICE ACCOUNTS & IAM)
# -----------------------------------------------------------------------------------------
# Erstellt die Identität, die das Backend später "trägt"
resource "google_service_account" "backend_sa" {
  account_id   = "quiz-backend-sa"
  display_name = "Cloud Run Backend Service Account"
  depends_on   = [time_sleep.wait_60_seconds]
}

# Rechtevergabe gemäß Sicherheitskonzept (Erlaubt Nutzung von Gemini)
resource "google_project_iam_member" "vertex_ai" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

# Cloud Run Service Agent
resource "google_project_iam_member" "run_service_agent" {
  project = var.project_id
  role    = "roles/run.serviceAgent"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

# Erlaubt DB Lese-/Schreibzugriff
resource "google_project_iam_member" "firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

# Erlaubt PDF Zugriff
resource "google_project_iam_member" "storage" {
  project = var.project_id
  role    = "roles/storage.objectUser"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}

# Erlaub dem Backen User zu löschen und Tokens zu prüfen
resource "google_project_iam_member" "firebase_auth_admin" {
  project = var.project_id
  role    = "roles/firebaseauth.admin"
  member  = "serviceAccount:${google_service_account.backend_sa.email}"
}


# -----------------------------------------------------------------------------------------
# 3. INFRASTRUKTUR (ARTIFACT REGISTRY)
# -----------------------------------------------------------------------------------------
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "quiz-backend-repo"
  description   = "Docker Repository for quiz-backend"
  format        = "DOCKER"
  depends_on    = [time_sleep.wait_60_seconds]
}


# -----------------------------------------------------------------------------------------
# 4. FIREBASE INITIALISIERUNG
# -----------------------------------------------------------------------------------------
resource "google_firebase_project" "default" {
  provider   = google-beta
  project    = var.project_id
  depends_on = [time_sleep.wait_60_seconds]
}

# Registriert die Android App
resource "google_firebase_android_app" "default" {
  provider     = google-beta
  project      = var.project_id
  display_name = "Unity Quiz App"
  package_name = var.android_package_name
  sha1_hashes  = var.android_sha1_hashes
  depends_on   = [google_firebase_project.default]
}

# Lädt die Config herunter, damit sie in Unity genutzt werden kann
data "google_firebase_android_app_config" "app_config" {
  provider   = google-beta
  project    = var.project_id
  app_id     = google_firebase_android_app.default.app_id
  depends_on = [google_firebase_android_app.default]
}

resource "local_file" "google_services_json" {
  content  = base64decode(data.google_firebase_android_app_config.app_config.config_file_contents)
  filename = "${path.module}/google-services.json"
}

# -----------------------------------------------------------------------------------------
# 5. STORAGE (BUCKET & RULES)
# -----------------------------------------------------------------------------------------
resource "google_storage_bucket" "pdf_bucket" {
  name                        = "${var.project_id}-pdf-uploads"
  location                    = var.region
  uniform_bucket_level_access = true

  # Löscht Dateien nach 1 Tag
  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "Delete"
    }
  }
  depends_on = [google_firebase_project.default]
}

resource "google_firebase_storage_bucket" "default_bucket_link" {
  provider   = google-beta
  project    = var.project_id
  bucket_id  = google_storage_bucket.pdf_bucket.name
  depends_on = [google_storage_bucket.pdf_bucket]
}

resource "google_firebaserules_ruleset" "storage_rules" {
  provider = google-beta
  project  = var.project_id
  source {
    files {
      name    = "storage.rules"
      content = file("storage.rules")
    }
  }
  depends_on = [google_firebase_storage_bucket.default_bucket_link]
}

resource "google_firebaserules_release" "storage_release" {
  provider     = google-beta
  name         = "firebase.storage/${google_storage_bucket.pdf_bucket.name}"
  ruleset_name = google_firebaserules_ruleset.storage_rules.name
  project      = var.project_id
  depends_on   = [google_firebaserules_ruleset.storage_rules]
}


# -----------------------------------------------------------------------------------------
# 6. DATENBANK (FIRESTORE)
# -----------------------------------------------------------------------------------------
resource "google_firestore_database" "database" {
  provider    = google-beta
  project     = var.project_id
  name        = "(default)"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"
  depends_on  = [google_firebase_project.default]
}

resource "google_firebaserules_ruleset" "firestore_rules" {
  provider = google-beta
  project  = var.project_id
  source {
    files {
      name    = "firestore.rules"
      content = file("firestore.rules")
    }
  }
  depends_on = [google_firestore_database.database]
}

resource "google_firebaserules_release" "firestore_release" {
  provider     = google-beta
  name         = "cloud.firestore"
  ruleset_name = google_firebaserules_ruleset.firestore_rules.name
  project      = var.project_id
  depends_on   = [google_firebaserules_ruleset.firestore_rules]
}

# -----------------------------------------------------------------------------------------
# 7. BUILD PROCESS
# -----------------------------------------------------------------------------------------
resource "null_resource" "docker_build" {
  triggers = {
    # Rebuild bei Code-Änderung
    dir_sha1   = sha1(join("", [for f in fileset("${path.module}/backend", "**") : filesha1("${path.module}/backend/${f}")]))
    project_id = var.project_id
    region     = var.region
  }

  provisioner "local-exec" {
    # Baut Container und lädt ihn hoch
    command = "gcloud builds submit --tag ${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/quiz-backend:latest ./backend"
    environment = {
      GOOGLE_CLOUD_PROJECT = var.project_id
    }
  }
  depends_on = [
    google_artifact_registry_repository.repo,
    time_sleep.wait_60_seconds
  ]
}

# -----------------------------------------------------------------------------------------
# 8. COMPUTE (CLOUD RUN)
# -----------------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "backend" {
  name     = "quiz-backend"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.backend_sa.email
    scaling {
      max_instance_count = 5
    }
    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.name}/quiz-backend:latest"
      resources {
        limits = {
          cpu    = "1000m"
          memory = "1Gi"
        }
      }
      env {
        name  = "GCP_PROJECT"
        value = var.project_id
      }
    }
  }

  depends_on = [
    null_resource.docker_build,
    google_project_iam_member.vertex_ai,
    google_project_iam_member.firestore,
    google_firestore_database.database
  ]
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.backend.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}


# -----------------------------------------------------------------------------------------
# 9. AUTHENTICATION CONFIG
# -----------------------------------------------------------------------------------------
# Aktiviert Email und Password Login
resource "google_identity_platform_config" "default" {
  project = var.project_id

  sign_in {
    allow_duplicate_emails = false
    email {
      enabled           = true
      password_required = true
    }
  }
  depends_on = [google_firebase_project.default]
}