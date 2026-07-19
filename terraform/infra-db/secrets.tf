resource "aws_secretsmanager_secret" "database" {
  for_each = local.database_secret_names

  name        = each.value
  description = "Empty secret container for ${each.value}. Values are synchronized in a later database secrets phase."

  tags = merge(local.common_tags, {
    Component = "secrets"
  })
}
