resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS SQL Server without application ingress until workload security groups are known."
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name      = "${var.project_name}-rds-sg"
    Component = "database"
  })
}

resource "aws_vpc_security_group_ingress_rule" "rds_admin_ssms" {
  count = local.rds_admin_access_enabled ? 1 : 0

  security_group_id = aws_security_group.rds.id
  description       = "Optional SQL Server admin access from the configured CIDR."

  cidr_ipv4   = local.rds_admin_cidr
  from_port   = var.rds_port
  ip_protocol = "tcp"
  to_port     = var.rds_port

  tags = merge(local.common_tags, {
    Name      = "${var.project_name}-rds-admin-ssms"
    Component = "database"
  })
}
