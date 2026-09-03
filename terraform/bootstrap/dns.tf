# Delegated subdomain
# Only NS records for this label are delegated here
# Nothing in this account can affect the apex domain.

resource "aws_route53_zone" "demo" {
  name    = var.dns_zone_name
  comment = "Delegated subdomain for ${var.project}"
}