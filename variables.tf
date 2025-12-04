variable "project_id" {
  description = "Google Cloud Projekt ID"
  type        = string
}

variable "region" {
  description = "Region der Ressourcen"
  type        = string
  default     = "us-central1"
}

variable "android_package_name" {
  description = "Package Name der Android App "
  type        = string
}

variable "android_sha1_hashes" {
  description = "SHA1 hash für die Android App"
  type        = list(string)
  default     = []
}

