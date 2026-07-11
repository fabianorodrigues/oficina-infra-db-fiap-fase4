output "vpc_id" {
  description = "Created VPC ID."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = aws_subnet.private[*].id
}

output "rds_identifier" {
  description = "RDS SQL Server identifier."
  value       = aws_db_instance.sqlserver.identifier
}

output "rds_endpoint" {
  description = "RDS SQL Server endpoint address."
  value       = aws_db_instance.sqlserver.address
}

output "rds_port" {
  description = "RDS SQL Server port."
  value       = aws_db_instance.sqlserver.port
}

output "rds_security_group_id" {
  description = "Security Group ID attached to RDS."
  value       = aws_security_group.rds.id
}

output "rds_master_secret_arn" {
  description = "ARN of the RDS-managed master secret."
  value       = aws_db_instance.sqlserver.master_user_secret[0].secret_arn
}

output "database_secret_arns" {
  description = "Secret container ARNs for future database runtime and migration credentials."
  value       = { for name, secret in aws_secretsmanager_secret.database : name => secret.arn }
}
