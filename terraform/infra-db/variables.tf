variable "aws_region" {
  description = "AWS region used by the target account."
  type        = string

  validation {
    condition     = length(trimspace(var.aws_region)) > 0
    error_message = "aws_region must not be empty."
  }
}

variable "project_name" {
  description = "Logical project name used in resource names and tags."
  type        = string
  default     = "oficina"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.project_name))
    error_message = "project_name must use lowercase letters, numbers and hyphens."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the independent VPC."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block."
  }
}

variable "availability_zone_count" {
  description = "Number of Availability Zones used by this stack."
  type        = number
  default     = 2

  validation {
    condition     = var.availability_zone_count == 2
    error_message = "This phase must use exactly two Availability Zones."
  }
}

variable "rds_identifier" {
  description = "RDS SQL Server instance identifier."
  type        = string
  default     = "oficina-sqlserver"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,61}[a-z0-9]$", var.rds_identifier)) && !strcontains(var.rds_identifier, "--")
    error_message = "rds_identifier must be a valid lowercase RDS identifier without consecutive hyphens."
  }
}

variable "rds_engine" {
  description = "RDS SQL Server engine edition. The default is a small edition; confirm availability during the first real plan."
  type        = string
  default     = "sqlserver-ex"

  validation {
    condition     = length(trimspace(var.rds_engine)) > 0
    error_message = "rds_engine must not be empty."
  }
}

variable "rds_instance_class" {
  description = "RDS instance class. The default must be validated during the first real plan."
  type        = string
  default     = "db.t3.micro"

  validation {
    condition     = length(trimspace(var.rds_instance_class)) > 0
    error_message = "rds_instance_class must not be empty."
  }
}

variable "rds_allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20

  validation {
    condition     = var.rds_allocated_storage > 0
    error_message = "rds_allocated_storage must be positive."
  }
}

variable "rds_storage_type" {
  description = "RDS storage type. gp3 is preferred when supported by the chosen SQL Server configuration."
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp2", "gp3"], var.rds_storage_type)
    error_message = "rds_storage_type must be gp2 or gp3."
  }
}

variable "rds_port" {
  description = "SQL Server listener port."
  type        = number
  default     = 1433

  validation {
    condition     = var.rds_port >= 1 && var.rds_port <= 65535
    error_message = "rds_port must be between 1 and 65535."
  }
}

variable "rds_master_username" {
  description = "Master username. The password is managed by RDS Secrets Manager integration."
  type        = string
  default     = "oficina_admin"

  validation {
    condition     = length(trimspace(var.rds_master_username)) > 0 && !contains(["admin", "sa", "root"], lower(var.rds_master_username))
    error_message = "rds_master_username must not be empty or a generic admin name."
  }
}

variable "common_tags" {
  description = "Additional non-environment tags to merge into all taggable resources."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.common_tags), "Environment")
    error_message = "common_tags must not include Environment."
  }
}
