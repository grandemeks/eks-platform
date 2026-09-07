variable "app_hostname" {
  description = "Fully qualified hostname the demo application is served on."
  type        = string
  default     = "incode-demo.grandemeks.tech"
}

variable "additional_hostnames" {
  description = "Extra names on the same certificate. Grafana shares the application's load balancer through the ALB group annotation, so it has to appear here."
  type        = list(string)
  default     = ["grafana.incode-demo.grandemeks.tech"]
}

resource "aws_acm_certificate" "app" {
  domain_name               = var.app_hostname
  subject_alternative_names = var.additional_hostnames
  validation_method         = "DNS"

  # Adding a SAN reissues the certificate. Create the replacement before the old
  # one is detached from the load balancer.
  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = var.app_hostname }
}

# The zone is in this account, so the validation CNAMEs are written here rather
# than by hand in the console.
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = aws_route53_zone.demo.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # Both names share a parent zone and can emit an identical validation record.
  allow_overwrite = true
}

# Blocks until ACM issues. Without it a listener can reference a certificate
# still in PENDING_VALIDATION.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
