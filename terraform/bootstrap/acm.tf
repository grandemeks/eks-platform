variable "app_hostname" {
  description = "Fully qualified hostname the demo application is served on."
  type        = string
  default     = "incode-demo.grandemeks.tech"
}

variable "additional_hostnames" {
  description = <<-EOT
    Extra names on the same certificate. Grafana shares the application's load
    balancer through the ALB group annotation, so it needs to be on the same
    certificate — one ALB and one certificate rather than two of each.
  EOT
  type        = list(string)
  default     = ["grafana.incode-demo.grandemeks.tech"]
}

resource "aws_acm_certificate" "app" {
  domain_name               = var.app_hostname
  subject_alternative_names = var.additional_hostnames
  validation_method         = "DNS"

  # ACM cannot modify a certificate in place, so adding a name means issuing a
  # new one. Creating the replacement first keeps the old certificate attached
  # to the load balancer until the new one is ready.
  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = var.app_hostname }
}

# ACM asks for a CNAME per name to prove control of the domain. Because the
# zone is in this account, Terraform writes them automatically — the whole
# chain from request to issued certificate is code, with no console step.
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

  # Both names validate into the same zone and can produce identical records
  # when they share a parent, so overwriting is expected rather than a conflict.
  allow_overwrite = true
}

# Blocks until ACM has actually issued the certificate. Without this, a load
# balancer could reference one still in PENDING_VALIDATION and the apply would
# fail with an error that points nowhere useful.
resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
