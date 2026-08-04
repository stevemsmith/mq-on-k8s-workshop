variable "namespace" {
  type        = string
  description = "Kubernetes namespace to deploy IBM MQ into."
  default     = "mq"
}

variable "kube_context" {
  type        = string
  description = "kubeconfig context to deploy against."
  default     = "docker-desktop"
}

variable "qmgr_name" {
  type        = string
  description = "Name of the IBM MQ queue manager."
  default     = "qm1"
}

variable "image" {
  type        = string
  description = "Image built by ../docker, in the form repository:tag."
  default     = "moov-mq:local"
}

variable "certs_dir" {
  type        = string
  description = "Local directory containing TLS materials produced by ../certs/create-certs.sh"
  default     = "../certs/out"
}

variable "mq_admin_password" {
  type        = string
  description = "Password for the 'admin' user in the IBM MQ Web Console. Workshop-only value, not a real secret - do not reuse this pattern outside a local tutorial."
  default     = "workshopadmin1"
  sensitive   = true
}
