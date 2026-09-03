variable "app_hostname" {
  description = "Fully qualified hostname the demo application is served on."
  type        = string
  default     = "incode-demo.grandemeks.tech"
}

resource "aws_acm_certificate" "app" {
  domain_name       = var.app_hostname
  validation_method = "DNS"

  # ACM cannot modify a certificate in place, so a domain change means a new
  # one. Creating the replacement first keeps the old certificate attached to
  # the load balancer until the new one is ready.
  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = var.app_hostname }
}

# ACM asks for a CNAME to prove control of the domain. Because the zone is in
# this account, Terraform writes it automatically — the whole chain from
# certificate request to issued certificate is code, with no console step.
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = aws_route53_zone.demo.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks until ACM has actually issued the certificate. Without this, a load
# balancer could reference a certificate still in PENDING_VALIDATION and the
# apply would fail with an error that points nowhere useful.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}