locals {
  repository_name = "oficina-infra-db-fiap-fase4"

  base_tags = {
    Project    = var.project_name
    ManagedBy  = "terraform"
    Repository = local.repository_name
  }

  common_tags = merge(local.base_tags, var.common_tags)

  selected_availability_zones = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)

  public_subnet_cidrs  = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, index)]
  private_subnet_cidrs = [for index in range(var.availability_zone_count) : cidrsubnet(var.vpc_cidr, 8, index + var.availability_zone_count)]

  database_secret_names = toset([
    "/oficina/cadastro/runtime-db",
    "/oficina/cadastro/migration-db",
    "/oficina/estoque/runtime-db",
    "/oficina/estoque/migration-db",
    "/oficina/ordens/runtime-db",
    "/oficina/ordens/migration-db",
    "/oficina/auth/database"
  ])

  ssm_parameters = {
    "/oficina/infra/vpc/id"                = aws_vpc.main.id
    "/oficina/infra/subnets/public/1"      = aws_subnet.public[0].id
    "/oficina/infra/subnets/public/2"      = aws_subnet.public[1].id
    "/oficina/infra/subnets/private/1"     = aws_subnet.private[0].id
    "/oficina/infra/subnets/private/2"     = aws_subnet.private[1].id
    "/oficina/infra/rds/identifier"        = aws_db_instance.sqlserver.identifier
    "/oficina/infra/rds/endpoint"          = aws_db_instance.sqlserver.address
    "/oficina/infra/rds/port"              = tostring(aws_db_instance.sqlserver.port)
    "/oficina/infra/rds/security-group-id" = aws_security_group.rds.id
    "/oficina/infra/rds/master-secret-arn" = aws_db_instance.sqlserver.master_user_secret[0].secret_arn
  }
}
