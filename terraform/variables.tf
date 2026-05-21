variable "region" {
  type        = string
  default     = "eu-central-1"
  description = "AWS region"
}

variable "cluster_name" {
  type        = string
  default     = "mern-eks"
  description = "EKS cluster name"
}

variable "cluster_version" {
  type        = string
  default     = "1.30"
  description = "EKS Kubernetes version"
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium"]
  description = "EC2 instance types for the managed node group"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "alert_email" {
  type        = string
  description = "Email subscribed to the SNS alarms topic"
  default     = ""
}

variable "github_repo" {
  type        = string
  description = "owner/repo allowed to assume the CI role via OIDC"
  default     = ""
}
