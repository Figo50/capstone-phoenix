variable "aws_region" {
  description = "AWS region to provision into"
  type        = string
  default     = "eu-north-1"
}

variable "admin_cidr" {
  description = "Your own IP, /32, allowed to reach SSH (22) and the k3s API (6443). Update this if your ISP changes your IP - run `curl -s https://checkip.amazonaws.com` and append /32."
  type        = string
  # 197.211.52.2/32 as of 2026-09-20 - replace via -var or terraform.tfvars if it changes
  default     = "197.211.52.2/32"
}

variable "instance_type" {
  description = "EC2 instance type for all nodes"
  type        = string
  default     = "t3.small"
}

variable "worker_count" {
  description = "Number of k3s worker (agent) nodes"
  type        = number
  default     = 2
}

variable "availability_zone" {
  description = "AZ for the public subnet"
  type        = string
  default     = "eu-north-1a"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key used for the AWS key pair"
  type        = string
  default     = "~/.ssh/capstone_key.pub"
}
