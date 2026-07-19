resource "aws_db_subnet_group" "sqlserver" {
  name        = "${var.project_name}-db-subnet-group"
  description = "Private subnets for Oficina SQL Server RDS."
  subnet_ids  = aws_subnet.private[*].id

  tags = merge(local.common_tags, {
    Name      = "${var.project_name}-db-subnet-group"
    Component = "database"
  })
}

resource "aws_db_instance" "sqlserver" {
  identifier = var.rds_identifier

  engine         = var.rds_engine
  instance_class = var.rds_instance_class
  license_model  = "license-included"
  port           = var.rds_port

  allocated_storage = var.rds_allocated_storage
  storage_type      = var.rds_storage_type
  storage_encrypted = true

  username                    = var.rds_master_username
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.sqlserver.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 1
  copy_tags_to_snapshot   = true
  deletion_protection     = false
  skip_final_snapshot     = true

  auto_minor_version_upgrade = true

  tags = merge(local.common_tags, {
    Name      = var.rds_identifier
    Component = "database"
  })
}
