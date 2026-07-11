resource "aws_ssm_parameter" "configuration" {
  for_each = local.ssm_parameters

  name  = each.key
  type  = "String"
  value = each.value

  tags = merge(local.common_tags, {
    Component = "configuration"
  })
}
