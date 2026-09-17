# Decisions

My notes for walking through this platform: why each choice, what I rejected, what it costs me, and where I'd take it next. Settings that are just settings are in the code, each with a comment.

## Short version

Terraform builds AWS in two stacks. Argo CD owns everything inside the cluster. CI builds, scans, signs and commits, with no cluster credentials, so the worst it can do is push a bad image to one ECR repo. Metrics, logs and traces are cross-linked, so an alert gets you to a trace and the trace gets you to the logs.

## Demo path

1. `https://incode-demo.grandemeks.tech`. The response shows which pod served it, plus the trace ID.
2. Grafana, demo-app dashboard, latency panel, click an exemplar dot. That exact trace opens in Tempo.
3. In the trace, "Logs for this span" gives the pod's log lines from that window.
4. Grafana, Alerting, switch the source to the Alertmanager datasource. `Watchdog` sits there delivered, which is how I know the alert path is alive.
5. `kubectl -n argocd get applications`: 9 apps, 3 sync waves.
6. Live change: edit a value in Git, push, watch Argo pick it up.

---

## Decisions

Each one: what I picked, what I turned down, what it costs, and where I'd take it.

**Two Terraform stacks, not one.** `bootstrap` holds what survives a teardown (state, KMS key, DNS zone, ECR with its images, ACM cert), about $1.50/month left running. `envs/dev` is destroyed between sessions. Two state files means a `destroy` in one can't reach the other, which workspaces wouldn't give me, and they're coupled by a KMS alias lookup rather than remote state so there's no read dependency.\
*Costs me:* a second `terraform init`, and a rebuild changes ARNs that Git has to be told about.\
*Next:* a third stack for anything shared across environments once there's more than one.

**I hand-wrote the EKS module.** Only because I have to explain every line here, and a 3000-line module I didn't write is the opposite of that.\
*Costs me:* edge cases the community module already handles, and maintenance I'd rather not own.\
*Next:* on a real team, swap to the community module and keep only the opinionated bits.

**One NAT gateway, not one per AZ.** About $0.045/h plus $0.045/GB. I looked at `fck-nat` on a `t4g.nano`, roughly a tenth of the cost but I own the AMI and its patching, and at VPC endpoints with no NAT at all, which is the best security answer but similar cost over a short run.\
*Costs me:* one AZ's NAT failure takes out all egress.\
*Next:* one per AZ in production. Endpoints for S3 and ECR regardless, since that traffic never needs to leave AWS.

**`t3.large` x2, on-demand.** Observability alone wants ~4.5 GB, so `t3.medium` leaves no headroom.\
*Costs me:* ~70% more than spot.\
*Next:* Karpenter with spot for stateless workloads and on-demand for the stateful ones.

**`authentication_mode = "API"`, creator admin permissions off.** The old `aws-auth` ConfigMap is a classic way to lock yourself out with no recovery except AWS support. With creator permissions on, "who has admin" depends on whether the first apply ran from my laptop or CI. Now every admin is an explicit access entry, plus whoever runs the apply, resolved through `aws_iam_session_context` since an assumed-role session ARN isn't something an access entry accepts.\
*Costs me:* the admin list is a variable someone has to maintain.\
*Next:* map entries to SSO groups rather than individual principals.

**RDS manages its own master password.** It generates and rotates it in Secrets Manager and Terraform never sees it, so it can't leak through state or a CI log.\
*Costs me:* the secret ARN changes on every rebuild, which is the entire reason `scripts/sync-values.sh` exists, and it means the app is Degraded for the first ten minutes of every rebuild while Argo still has the previous ARN.\
*Next:* IAM database authentication and drop the password entirely. That removes the secret, the sync step and the race in one move.

**The app's service account has no AWS identity.** A second service account exists only for External Secrets to impersonate, and it can read exactly one secret ARN. A compromised app pod has no route to AWS even though a secret reader sits in the same namespace. Same idea in IAM: `kms:ViaService` means the identity can use the platform key only through Secrets Manager, so it can't decrypt Terraform state with it.\
*Costs me:* two service accounts per workload instead of one.\
*Next:* the same split for every workload that gains an AWS dependency, and a Kyverno policy that rejects a pod whose own SA carries a role annotation.

**Liveness doesn't touch the database, readiness does.** If liveness checked it, an RDS failover would restart every replica at once and turn a recoverable dependency failure into a self-inflicted outage.\
*Costs me:* a pod that can never reach its database stays Running forever instead of crashing loudly.\
*Next:* nothing. I deliberately broke the database to test this and both pods recovered on their own with zero restarts.

**Traces on the OTel SDK, metrics on the Prometheus client.** OTel's HTTP conventions would rename `http_requests_total`, which rewrites every recording rule and burn-rate alert as a side effect of a plumbing change. Exemplars join the two, so I get correlation without the migration.\
*Costs me:* two instrumentation libraries in one binary.\
*Next:* green-field, all-OTel with the rules written against OTel names from day one.

**One collector in DaemonSet mode, doing logs and traces.** Agent-plus-gateway earns its keep once you need tail sampling or a single vendor egress; with two nodes and one app it's two hops and double the memory. DaemonSet isn't optional for logs anyway, since `filelog` reads `/var/log/pods` off the host.\
*Costs me:* no central place to sample or filter, and `AlwaysSample` doesn't survive real traffic.\
*Next:* gateway deployment, `TraceIDRatioBased` in the SDK, tail sampling in the gateway so errors and slow requests stay at 100%.

**Burn-rate alerts, not `CPU > 80%`.** Budget is 0.5% of requests over 30 days. Burn rate 1 means you run out exactly at the end of the window, 14.4 means gone in two days. Each alert pairs a long window with a short one so it clears when the incident does. Four thresholds, two paging and two ticketing.\
*Costs me:* seven recording rules and a definition that needs explaining to anyone new.\
*Next:* multi-service SLOs and an error-budget policy that actually gates releases.

**Terraform installs Argo CD and nothing else in the cluster.** Everything after that is an Argo `Application`, so adding a component is a PR rather than a Terraform change, and the release pipeline needs no cluster credentials because it ends with a commit. I looked at Amazon EKS Capabilities (managed Argo CD, GA Nov 2025) and rejected it: bills separately, and I can't demo infra in an account I don't control.\
*Costs me:* I own Argo's upgrades and CVEs.\
*Next:* in production I'd probably take the managed option for exactly that reason.

**Deploy by digest, signed with keyless cosign.** A signature covers a digest, not a tag. The identity is the workflow's OIDC token via Fulcio, logged in Rekor, so there's no key to store or leak.\
*Costs me:* nothing today, because nothing verifies it. It's provenance, not a control.\
*Next:* a Kyverno `verifyImages` policy. The signatures have to exist before you can turn that on, which is why signing now is worth it.

---

## Bugs I found and fixed

Every one has the same shape: config that looks right, is accepted without complaint, and does nothing.

**Traces never left the pod, for the whole life of the environment.** `OTEL_EXPORTER_OTLP_ENDPOINT` is a *base* URL per the spec, but the SDK's `WithEndpointURL` treats its argument as the *complete* traces URL and, given no path, sets it to `/` on purpose so the default can't apply. The collector only serves `/v1/traces`, so every export got a 404. Nothing looked wrong: app `Healthy`, `"tracing":true` in the log, valid trace IDs handed to callers and attached to exemplars Prometheus stored, all pointing at traces that didn't exist. I found it by looking for a counter that should exist and didn't: `otelcol_receiver_accepted_spans` was missing entirely rather than zero, so it had never been incremented once.

**The 404 was reported correctly and still invisible.** The SDK sends async errors to its global handler, which writes to Go's `log` package, which `slog.SetDefault` routes into the JSON handler at **INFO**. A dead trace pipeline read as one unremarkable info line. Now it goes through `slog` at ERROR.

**And the collector wasn't being scraped**, which is why it could stay dead quietly. `serviceMonitor.enabled: true` is accepted and does nothing in `daemonset` mode: the chart only renders a ServiceMonitor next to a Service, and renders neither unless `service.enabled` is set. Swapped to a PodMonitor, the right shape anyway since a Service in front of a DaemonSet scrapes one arbitrary pod per interval. The real gap was monitoring the monitoring.

**Alertmanager had never started. Not once, in any environment.** The `alertmanager.config` block is passed through as native Alertmanager YAML, which is snake_case; I'd written it in camelCase, which is the `AlertmanagerConfig` CRD's schema. The operator couldn't parse the secret, never created the StatefulSet, and Prometheus reported zero alertmanagers. Helm rendered it, Argo synced it, nothing complained. The routing tree I was proud of had never been executed. Found it by asking Prometheus which alertmanagers it had discovered, two days before the interview.

**Grafana's datasource plugins weren't registered.** Grafana 13 ships prometheus, loki and tempo as bundled plugins and its background installer unlinks each one before reinstalling a newer build. The unlink fails on a read-only root filesystem, and the plugin is left unregistered, so every query returned "Plugin not registered" and no panel would render. Every other signal was green: datasources provisioned with correct URLs, Argo Synced, pod 3/3 Running, login working. You only see it if you query *through* Grafana, and I had always been port-forwarding straight to Prometheus and Tempo instead. Fixed with `preinstall_disabled`, which keeps `readOnlyRootFilesystem: true`.

**Then that fix OOM-killed Grafana.** Registering 12 more plugin processes pushed startup memory from under the old ceiling to 340Mi against a 384Mi limit. I measured the peak rather than guessing a number, and raised the limit to 768Mi. Worth saying out loud: steady state was 241Mi and peak was 340Mi, so anyone sizing off steady state gets an OOM on every restart.

**external-dns structurally can't own a zone apex record.** Its ownership TXT prefixes the record type onto the first label. For `grafana.incode-demo…` that gives `cname-grafana.incode-demo…`, inside the zone, fine. For the apex it gives `cname-incode-demo.grandemeks.tech`, a sibling under the registrar-hosted parent, outside the delegated zone, dropped by `domainFilters`. So external-dns created the apex records, skipped the ownership TXT, and never saw them as its own again. After a rebuild the apex still pointed at the old ALB and the hostname stopped resolving, while the logs said "All records are already up to date" every minute. Fixed with `txtPrefix: "%{record_type}-."`, where the trailing dot makes the ownership record a subdomain instead of a sibling.

**Grafana's admin password was regenerated on every sync.** With `adminPassword` unset the chart calls `randAlphaNum`, which returns something new per render, and Argo renders every sync. So the Secret got rewritten and the pod restarted each time, but Grafana keeps its admin password in its own DB and won't overwrite an existing admin from env. Nobody could log in, and Grafana's own sidecars got 401 on the provisioning reload API. Now it comes from Secrets Manager through External Secrets, same as the DB credential.

**Fixing Alertmanager immediately broke the teardown.** `teardown.sh` deletes StatefulSets before PVCs, because the `pvc-protection` finalizer only clears once nothing mounts the volume. It never deleted the operator's custom resources, so the prometheus-operator saw the `Alertmanager` CR, recreated the StatefulSet, the new pod remounted the claim, and the delete hung. That race had been sitting there the whole time and could never fire, because Alertmanager had never successfully started. One fix surfaced the next. `teardown.sh` now deletes the operator's resources first.

**PostgreSQL CTE snapshot.** Every sub-statement of a `WITH` sees the same snapshot, so a sibling `SELECT` can't see the row a data-modifying CTE just inserted. The visit counter was permanently one behind. Reproduced in `psql`, then fixed by counting pre-insert and adding the new row explicitly. Reads perfectly, still wrong.

**GitHub's OIDC `sub` claim, twice.** On this account it carries numeric IDs, `repo:owner@<id>/repo@<id>:ref:…`, not the name form every example shows. And GitHub *rewrites* the claim when a job declares an `environment:`, so adding the approval gate broke auth by presenting `environment:dev`. STS never says which condition failed, so both were diagnosed by printing the real token from a workflow and diffing it against the trust policy.

## How I validated the alerting

I didn't want to claim the alert path worked without proving it, so I broke the database on purpose: revoked the PostgreSQL ingress rule on the RDS security group and watched.

The first thing I learned is that nothing happened. Security groups are stateful, so revoking a rule blocks new connections while the existing pgx pool keeps serving; `MaxConnLifetime` is 30 minutes. A network partition doesn't show up until connections churn. I deleted a pod to force fresh ones.

Then the whole chain ran: 503 rather than a hanging request, an ERROR log line carrying a `trace_id` that resolves in Tempo, `app_database_up` at 0 on the broken pod and 1 on the healthy one, the alert moving inactive to pending to firing after its two-minute window, and landing in Alertmanager with `severity: critical` routed to the `pager` receiver and carrying its runbook URL. Restoring the rule brought both pods back with zero restarts, because readiness checks the database and liveness doesn't.

Total outage 3 minutes 44 seconds, entirely self-inflicted and entirely reversible.

## Rough edges, which I'd rather say first

- **A PR can assume the Terraform admin role.** The trust policy trusts `pull_request`, and for those events GitHub runs the workflow file from the head branch, so a PR could add a step that assumes the role. The workflow split is a guard rail against an `if:` mistake, not a boundary; branch protection and the required reviewer are the real controls. Proper fix is a separate read-only plan role.
- **Both app replicas can land on one node.** `topologySpreadConstraints` uses `whenUnsatisfiable: ScheduleAnyway`, so spreading is a preference. Right now both pods are on the same node, which means two replicas and a PDB still go down together if that node does. `DoNotSchedule` with two nodes risks a Pending pod during a node replacement, which is why it's set this way, but it's a real availability gap.
- **No Go job in CI.** `pr-checks` triggers on `app/**` but never builds, vets or tests it. Matters more now that `tracing_test.go` pins the one thing about the exporter you can't see from outside the process.
- **`terraform fmt -check -recursive` never sees `terraform/modules/`**, because CI runs it per-stack with a `working-directory`, and most of the code is in `modules/`.
- **`teardown.sh` doesn't touch Route53.** Cleanup relies on external-dns still running when the Ingress is deleted.
- **The `checksum/db-secret` annotation doesn't roll pods on rotation.** It hashes the secret's ARN and RDS rotates in place, so the hash never changes. Right mechanism, wrong input; it should hash the Kubernetes Secret's resourceVersion.
- **Logs only carry a trace ID on the error path.** That's deliberate, since per-request logging is expensive and the trace already has the timing, but it means the log-to-trace link is idle until something fails.
- Single-AZ RDS, single NAT, no autoscaler, no NetworkPolicy. Cost choices for a demo, all things I'd change for prod.

## What I'd do next, in order

1. **Alert on the telemetry pipeline itself.** `absent(otelcol_receiver_accepted_spans)` while the app is serving, and `rate(otelcol_exporter_send_failed_spans[5m]) > 0`. Both of today's observability bugs would have paged in minutes instead of hiding.
2. **A synthetic check that asserts a trace is retrievable.** Generate a request, take the trace ID from the response, fetch it from Tempo. That tests the whole chain rather than each hop, and it's the only test that would have caught the OTLP path bug.
3. **A Go job in CI.** Build, vet and test on every PR touching `app/**`.
4. **Split the CI role.** Read-only plan role trusted for `pull_request`, apply role trusted only for `main`.
5. **Kyverno `verifyImages`**, to turn signing from provenance into a control.
6. **Then scale:** gateway collector with tail sampling, Thanos or Mimir on S3, S3-backed Loki and Tempo, multi-AZ RDS with failover testing, Karpenter, NetworkPolicies, a real Alertmanager receiver, and Grafana behind SSO.

The pattern worth naming: every bug above was a mechanism with no observable consequence. The defence isn't more care, it's making sure each one has a counter, and alerting on a counter's *absence* rather than its value.
