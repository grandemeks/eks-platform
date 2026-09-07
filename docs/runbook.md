# Runbook — demo-app

One section per alert in `helm-charts/demo-app/templates/prometheusrule.yaml`. Each alert's `runbook_url` points here.

Assumed shell setup:

```bash
export AWS_PROFILE=eks-platform AWS_REGION=eu-central-1
export KUBECONFIG=$PWD/.kubeconfig
aws eks update-kubeconfig --name eks-platform-dev --region eu-central-1
```

Grafana: `https://grafana.incode-demo.grandemeks.tech` — dashboard **demo-app**. The admin credential is in Secrets Manager:

```bash
aws secretsmanager get-secret-value --secret-id eks-platform-dev-grafana-admin --query SecretString --output text
```

---

## Error budget burn

Fires as `DemoAppErrorBudgetBurnFast` / `Moderate` (critical, pages) or `Slow` / `VerySlow` (warning, ticket).

**What it means.** The SLO is 99.5% availability over 30 days, so the error budget is 0.5% of requests. Burn rate 1 means the budget will be exactly exhausted at the end of the window; 14.4 means it is gone in about two days. Each alert requires both a long window (the burn is real, not a blip) and a short one (it is still happening right now), so it clears when the incident does.

**First look — is it errors or is it the database?**

```bash
kubectl -n demo get pods -o wide
kubectl -n demo logs -l app.kubernetes.io/name=demo-app --tail=50 | grep -i error
```

In Grafana: **Traffic by route and status** shows which status code is rising; **Error ratio over time** against the 0.5% line shows the shape.

**Then find one failing request rather than reasoning about aggregates.** On the **Latency quantiles** panel, click an exemplar dot to open that exact trace in Tempo, then use "Logs for this span" to read what the pod logged while serving it.

**Common causes, in the order they actually happen here:**

| Symptom | Cause | Action |
|---|---|---|
| 503s, `app_database_up` is 0 | database unreachable | see [Database unreachable](#database-unreachable) |
| 503s, `app_database_up` is 1 | request timeout hit (3 s) under slow queries | check **Database query latency p99**; check RDS Performance Insights |
| 5xx right after a deploy | bad release | roll back by reverting the digest commit — see below |
| errors on one pod only | that replica or its node | `kubectl -n demo delete pod <name>`; check node pressure |

**Rolling back.** The deployed digest lives in Git, so a rollback is a revert:

```bash
git log --oneline -- argocd/configs/demo-app/values-dev.yaml
git revert --no-edit <the release commit>
git push
```

Argo CD reconciles within 3 minutes, or force it:

```bash
kubectl -n argocd annotate app demo-app argocd.argoproj.io/refresh=hard --overwrite
kubectl -n demo rollout status deploy/demo-app
```

Do **not** fix this with `kubectl set image` — `selfHeal: true` will revert it and the drift will confuse the next responder.

---

## Database unreachable

Fires as `DemoAppDatabaseUnreachable` when `app_database_up == 0` for 2 minutes.

Readiness fails while this holds, so affected pods leave the load balancer without being killed. If every replica is affected the service is down; if one is, the ALB is already routing around it.

**Check the database itself:**

```bash
aws rds describe-db-instances --query 'DBInstances[0].{status:DBInstanceStatus,az:AvailabilityZone,class:DBInstanceClass}'
kubectl -n demo logs -l app.kubernetes.io/name=demo-app --tail=30 | grep -i 'database\|readiness'
```

**Check the credential path.** External Secrets syncs the RDS-managed password into a Kubernetes Secret; the ARN changes whenever the environment is rebuilt.

```bash
kubectl -n demo get externalsecret,secret
kubectl -n demo describe externalsecret demo-app-db | tail -20
kubectl -n external-secrets logs -l app.kubernetes.io/name=external-secrets --tail=30
```

If the ExternalSecret is not `SecretSynced`, the usual cause is a stale secret ARN in `argocd/configs/demo-app/values-dev.yaml` after a rebuild. Fix it at the source, not by hand:

```bash
./scripts/sync-values.sh
git add argocd/ && git commit -m "chore: sync values" && git push
```

**Check reachability** — the pod-to-RDS path is a security group reference to the EKS cluster SG, so it survives subnet changes but not a security group replacement:

```bash
aws rds describe-db-instances --query 'DBInstances[0].VpcSecurityGroups'
kubectl get nodes -o jsonpath='{.items[0].spec.providerID}'
```

**Do not restart pods to "fix" this.** Liveness deliberately does not check the database, precisely so a database outage does not restart every replica. Restarting turns a recoverable dependency failure into a self-inflicted one.

---

## Latency objective violated

Fires as `DemoAppLatencyObjectiveViolated` when more than the allowed fraction of requests exceed 250 ms over 5 minutes.

The buckets are chosen so 0.25 is a real bucket boundary — this is an exact count, not an interpolation, so the number can be trusted.

```bash
kubectl -n demo top pods
kubectl -n demo get hpa 2>/dev/null   # none configured; scaling is manual here
```

In Grafana, compare **Latency quantiles** against **Database query latency p99**. If both rose together the database is the cause; if only the HTTP latency rose, look at **CPU per pod** and **Memory per pod** against their request and limit lines — a pod at its CPU request on a busy node is throttled, not broken.

Then click an exemplar on the slow bucket and read the trace: the `db.record_visit` span shows exactly how much of the request was database time.

---

## No traffic

Fires as `DemoAppNoTraffic` when `absent(up{job="demo-app"} == 1)` holds for 5 minutes — either every replica is gone or scraping has broken. Both look identical from Prometheus and both are urgent.

`absent()` is used deliberately: a rate comparison would never fire, because with no series there is nothing to compare.

```bash
kubectl -n demo get pods,servicemonitor
kubectl -n argocd get applications
```

Check the scrape target in Prometheus:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
open http://localhost:9090/targets
```

**If the pods are healthy but the target is missing**, the ServiceMonitor has stopped matching. Its selector is the chart's selector labels, and `serviceMonitorSelectorNilUsesHelmValues: false` is what lets Prometheus adopt it at all — a target dropped this way produces no error anywhere.

**If the pods are gone**, check whether Argo CD removed them:

```bash
kubectl -n argocd get app demo-app -o jsonpath='{.status.sync}{"\n"}{.status.conditions}'
```

**If the hostname does not resolve but pods are healthy**, this is DNS, not the application:

```bash
dig +short incode-demo.grandemeks.tech
kubectl -n demo get ingress
aws elbv2 describe-load-balancers --query 'LoadBalancers[].DNSName'
kubectl -n kube-system logs deploy/external-dns --tail=20
```

Compare the alias target in Route53 against the ALB that actually exists — a mismatch means the record points at a load balancer from a previous environment:

```bash
aws route53 list-resource-record-sets --hosted-zone-id "$(aws route53 list-hosted-zones-by-name \
  --dns-name incode-demo.grandemeks.tech --query 'HostedZones[0].Id' --output text | cut -d/ -f3)" \
  --query "ResourceRecordSets[?Type=='A'].{N:Name,T:AliasTarget.DNSName}" --output table
```

external-dns only modifies records carrying its own ownership TXT. If the A record has no matching `a-.` / `aaaa-.` TXT beside it, external-dns will never correct it — delete the A/AAAA records and let it recreate them together with their ownership record.

---

## Telemetry itself looks broken

Not an alert, but the failure mode that hides every other one: if the pipeline is down, everything goes quiet and looks healthy.

**Are spans arriving at all?** This counter does not exist until the first span is received, which makes its absence the signal:

```bash
COLIP=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=opentelemetry-collector \
  -o jsonpath='{.items[0].status.podIP}')
kubectl -n monitoring run curltest --rm -i --restart=Never --image=curlimages/curl:latest \
  --command -- sh -c "curl -s http://$COLIP:8888/metrics | grep -E 'accepted_spans|send_failed_spans'"
```

`accepted_spans` present and `send_failed_spans` zero means the app-to-collector and collector-to-Tempo hops are both fine. `accepted_spans` missing entirely means the application is not exporting — check its logs for export errors, which are emitted through the OTel error handler at ERROR level.

**Generate traffic before checking exemplars.** A histogram with no observations has no exemplars, which looks identical to exemplars being broken:

```bash
for i in $(seq 1 20); do curl -s https://incode-demo.grandemeks.tech/ >/dev/null; done
curl -s https://incode-demo.grandemeks.tech/ | jq -r .trace_id
```

Then confirm the trace exists in Tempo, which proves the whole chain:

```bash
kubectl -n monitoring port-forward svc/tempo 3200:3200 &
curl -s "localhost:3200/api/traces/<trace_id>" | jq '.batches[0].resource.attributes'
```

Tempo's query API is on **3200**. 3100 is Loki.
