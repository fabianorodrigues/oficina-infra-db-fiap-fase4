resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS SQL Server without application ingress until workload security groups are known."
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name      = "${var.project_name}-rds-sg"
    Component = "database"
  })
}
