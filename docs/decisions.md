# Decisions

My notes for walking through this platform: the choices where there was a real alternative, and the bugs I hit. Settings that are just settings are in the code, each with a comment explaining it.

## Short version

Terraform builds AWS in two stacks. Argo CD owns everything inside the cluster. CI builds, scans, signs and commits, with no cluster credentials, so the worst it can do is push a bad image to one ECR repo. Metrics, logs and traces are cross-linked, so an alert gets you to a trace and the trace gets you to the logs.

## Demo path

1. `https://incode-demo.grandemeks.tech`. The response shows which pod served it, plus the trace ID.
2. Grafana - demo-app dashboard - latency panel - click an exemplar dot. That exact trace opens in Tempo.
3. In the trace, "Logs for this span" gives the pod's log lines from that window.
4. `kubectl -n argocd get applications`: 9 apps, 3 sync waves.
5. Live change: edit a value in Git, push, watch Argo pick it up.

---

## Choices where there was a real alternative

**Two Terraform stacks, not one.** `bootstrap` holds what survives a teardown (state, KMS key, DNS zone, ECR with its images, ACM cert), about $1.50/month left running. `envs/dev` gets destroyed between sessions. Two state files means a `destroy` in one can't reach the other, which workspaces wouldn't give me. They're coupled by a KMS alias lookup rather than remote state, so there's no read dependency and no stale outputs.

**I hand-wrote the EKS module.** Only because I have to explain every line here, and a 3000-line module I didn't write is the opposite of that. On a real team I'd use the community module.

**One NAT gateway, not one per AZ.** About $0.045/h plus $0.045/GB. Alternatives were `fck-nat` on a `t4g.nano` (10x cheaper, but I own the AMI and its patching) or VPC endpoints with no NAT (best security, similar cost over a short run).

**`t3.large` x2, on-demand.** Observability alone wants ~4.5 GB, so `t3.medium` leaves no headroom. Spot saves ~70% but I don't want a node reclaimed mid-interview.

**`authentication_mode = "API"`, and creator admin permissions off.** The old `aws-auth` ConfigMap is a classic way to lock yourself out with no recovery except AWS support. And with `bootstrap_cluster_creator_admin_permissions = true`, "who has admin" depends on whether the first apply ran from my laptop or from CI. Now every admin is an explicit access entry, plus whoever runs the apply, resolved through `aws_iam_session_context` since an assumed-role session ARN isn't something an access entry accepts. That last part is what stops CI locking itself out of a cluster it just built.

**RDS manages its own master password.** It generates and rotates it in Secrets Manager and Terraform never sees it, so it can't leak through state or a CI log. The cost is that the secret ARN changes on every rebuild, which is the entire reason `scripts/sync-values.sh` exists.

**The app's service account has no AWS identity.** A second service account exists purely for External Secrets to impersonate, and it can read exactly one secret ARN. So a compromised app pod has no route to AWS even though a secret reader sits in the same namespace. Same idea in the IAM policy: `kms:ViaService` means the identity can use the platform key only through Secrets Manager, so it can't decrypt Terraform state with it.

**Liveness doesn't touch the database, readiness does.** If liveness checked it, an RDS failover would restart every replica at once and turn a recoverable dependency failure into a self-inflicted outage. Same reasoning behind a failed migration not being fatal: the pod comes up unready and recovers, instead of CrashLoopBackOff turning a 30-second blip into minutes of downtime.

**Shutdown fails readiness, sleeps 5s, then drains.** SIGTERM and endpoint removal race on pod delete, and removal has to reach kube-proxy on every node plus the ALB target group. Exit immediately and you close the socket while traffic is still arriving.

**Traces on the OTel SDK, metrics on the Prometheus client.** OTel's HTTP conventions would rename `http_requests_total`, which rewrites every recording rule and burn-rate alert as a side effect of a plumbing change. Exemplars join the two, so I get the correlation without the migration. Green-field I'd go all-OTel and write the rules against OTel names from the start.

**One collector in DaemonSet mode, doing logs and traces.** Agent-plus-gateway earns its keep once you need tail sampling or a single vendor egress; with two nodes and one app it's two hops and double the memory. DaemonSet isn't optional for logs anyway, since `filelog` reads `/var/log/pods` off the host. Traces take a node-local hop over `hostPort`, so losing one node's collector only affects that node's pods.

**Burn-rate alerts, not `CPU > 80%`.** Budget is 0.5% of requests over 30 days. Burn rate 1 means you run out exactly at the end of the window, 14.4 means gone in two days. Each alert pairs a long window (the burn is real) with a short one (it's still happening), so it clears when the incident does. Four thresholds, two paging and two ticketing, because "wake someone up" and "look at it Monday" are different responses.

**Terraform installs Argo CD and nothing else in the cluster.** Everything after that is an Argo `Application`, so adding a component is a PR rather than a Terraform change, and the release pipeline needs no cluster credentials because it ends with a commit. I looked at Amazon EKS Capabilities (managed Argo CD, GA Nov 2025) and rejected it: bills separately, and I can't demo infra in an account I don't control. In prod I'd probably take it, since it removes upgrade and CVE work on the GitOps engine itself.

**Deploy by digest, signed with keyless cosign.** A signature covers a digest, not a tag. The identity is the workflow's OIDC token via Fulcio, logged in Rekor, so there's no key to store or leak. It isn't enforced in-cluster yet, so today it's provenance rather than a control. The missing piece is a Kyverno `verifyImages` policy, and the signatures have to exist before you can turn that on.

---

## Bugs I found and fixed

**Traces never left the pod, for the whole life of the environment.** `OTEL_EXPORTER_OTLP_ENDPOINT` is a *base* URL per the spec, but the SDK's `WithEndpointURL` treats its argument as the *complete* traces URL and, given no path, sets it to `/` on purpose so the default can't apply. The collector only serves `/v1/traces`, so every export got a 404. Nothing looked wrong: app `Healthy`, `"tracing":true` in the log, valid trace IDs handed back to callers and attached to exemplars Prometheus stored, all pointing at traces that didn't exist. I found it by looking for a counter that should exist and didn't. `otelcol_receiver_accepted_spans` was missing entirely rather than zero, so it had never been incremented once, which ruled out the whole second half of the pipeline in one check.

**The 404 was reported correctly and still invisible.** The SDK sends async errors to its global handler, which writes to Go's `log` package, which `slog.SetDefault` routes into the JSON handler at **INFO**. A completely dead trace pipeline read as one unremarkable info line. Now it goes through `slog` at ERROR.

**And the collector wasn't being scraped**, which is why it could stay dead quietly. `serviceMonitor.enabled: true` is accepted and does nothing in `daemonset` mode: the chart only renders a ServiceMonitor next to a Service, and renders neither unless `service.enabled` is set. Swapped it to a PodMonitor, which is the right shape anyway since a Service in front of a DaemonSet scrapes one arbitrary pod per interval. The real gap was monitoring the monitoring.

**external-dns structurally can't own a zone apex record.** Its ownership TXT prefixes the record type onto the first label. For `grafana.incode-demo…` that gives `cname-grafana.incode-demo…`, inside the zone, fine. For the apex it gives `cname-incode-demo.grandemeks.tech`, a sibling under the registrar-hosted parent, outside the delegated zone, dropped by `domainFilters`. So external-dns created the apex records, skipped the ownership TXT, and never saw them as its own again. After a rebuild the apex still pointed at the old ALB and the hostname stopped resolving, while the logs said "All records are already up to date" every minute. Fixed with `txtPrefix: "%{record_type}-."`, where the trailing dot makes the ownership record a subdomain instead of a sibling.

**Grafana's admin password was regenerated on every sync.** With `adminPassword` unset the chart calls `randAlphaNum`, which returns something new per render, and Argo renders every sync. So the Secret got rewritten and the pod template's checksum over it restarted Grafana each time. But Grafana keeps its admin password in its own DB and won't overwrite an existing admin from env, so it kept accepting only the password from the first install. Nobody could log in, and Grafana's own sidecars got 401 on the provisioning reload API. Now it comes from Secrets Manager through External Secrets, same as the DB credential.

**PostgreSQL CTE snapshot.** Every sub-statement of a `WITH` sees the same snapshot, so a sibling `SELECT` can't see the row a data-modifying CTE just inserted. The visit counter was permanently one behind. Reproduced it in `psql`, then fixed it by counting pre-insert and adding the new row explicitly. Reads perfectly, still wrong.

**GitHub's OIDC `sub` claim, twice.** On this account it carries numeric IDs, `repo:owner@<id>/repo@<id>:ref:…`, not the name form every example shows. And GitHub *rewrites* the claim when a job declares an `environment:`, so adding the approval gate broke auth by presenting `environment:dev` instead of `ref:refs/heads/main`. STS never says which condition failed, so both were diagnosed by printing the real token from a workflow and diffing it against the trust policy.

The pattern in most of these is **config that looks right, is accepted without complaint, and does nothing.** The defence isn't being more careful, it's making sure every mechanism has an observable consequence you can assert on.

---

## Rough edges, which I'd rather say first

- **A PR can assume the Terraform admin role.** The trust policy trusts `pull_request`, and for those events GitHub runs the workflow file from the head branch, so a PR could add a step that assumes the role. The workflow split is a guard rail against an `if:` mistake, not a boundary; branch protection and the required reviewer are the real controls. Proper fix is a separate read-only plan role.
- **No Go job in CI.** `pr-checks` triggers on `app/**` but never builds, vets or tests it. Matters more now that `tracing_test.go` pins the one thing about the exporter you can't see from outside the process.
- **`terraform fmt -check -recursive` never sees `terraform/modules/`**, because CI runs it per-stack with a `working-directory`, and most of the code is in `modules/`.
- **`teardown.sh` doesn't touch Route53.** Cleanup relies on external-dns still running when the Ingress is deleted.
- **The `checksum/db-secret` annotation doesn't roll pods on rotation.** It hashes the secret's ARN and RDS rotates in place, so the hash never changes. Right mechanism, wrong input.
- Single-AZ RDS, single NAT, no autoscaler, no NetworkPolicy: cost choices for a demo, all things I'd change for prod.

## What prod would add

Tail sampling in a gateway collector, with ratio-based sampling in the SDK instead of `AlwaysSample`. Thanos or Mimir on S3 for long-term metrics. Multi-AZ RDS with failover testing. Kyverno enforcing signatures, Karpenter, NetworkPolicies, a real Alertmanager receiver, and Grafana behind SSO.
