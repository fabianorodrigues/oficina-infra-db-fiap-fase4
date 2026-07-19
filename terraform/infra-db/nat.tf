resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name      = "${var.project_name}-nat-eip"
    Component = "network"
  })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.common_tags, {
    Name      = "${var.project_name}-nat"
    Component = "network"
  })

  depends_on = [aws_internet_gateway.main]
}
