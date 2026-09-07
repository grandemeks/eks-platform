# Decisions

Talking points for walking through this platform. One line per decision, with the alternative that was rejected. The reasoning in depth is in the code comments — every non-obvious line says why it is there.

---

## The 30-second version

Terraform provisions AWS in two stacks. Argo CD owns everything inside the cluster. CI builds, scans, signs and commits — it holds no cluster credentials, so its worst case is one bad image in one ECR repository. Three observability signals are wired to each other in both directions, so a burn-rate alert leads to a trace and that trace leads to the logs.

## Suggested demo path

1. `https://incode-demo.grandemeks.tech` — response carries `hostname` and `trace_id`.
2. Grafana dashboard → latency panel → click an exemplar dot → the trace of that exact request opens in Tempo.
3. In the trace → "Logs for this span" → the pod's log lines in that window.
4. `kubectl -n argocd get applications` — nine Applications, three sync waves.
5. Make a live change: edit a value in Git, push, watch Argo reconcile.

---

## Architecture

- **Two Terraform stacks, not one.** `bootstrap` holds what must survive a teardown (state, KMS key, DNS zone, ECR with its images, ACM cert). `envs/dev` is destroyed between sessions. Separate state files mean a `destroy` in one cannot reach the other. Persistent layer costs about $1.50/month. Coupled only by a KMS **alias lookup** — no remote state reference, no outputs passed by hand.
- **S3 state with native locking** (`use_lockfile`), not the DynamoDB table. One less resource for the same guarantee. `prevent_destroy` on the bucket: everything else is reproducible from code, state history is not.
- **Hand-written EKS module, not the community module.** The brief asks me to explain every part; a 3000-line module I did not write is the opposite of that. In a real team I would use the community module — this choice is about the interview, and I would say so.

## Network

- **`/20` subnets keyed by AZ**, so a subnet's identity is stable when the AZ list changes.
- **One NAT gateway, not one per AZ.** ~$0.045/h + $0.045/GB. Alternatives: `fck-nat` on `t4g.nano` (~10x cheaper, AMI becomes my problem), or VPC interface endpoints and no NAT at all (best security — traffic never leaves AWS — but five endpoints cost about the same over a short run).
- **Subnet tags `kubernetes.io/role/elb`.** The load balancer controller discovers subnets by tag. Without them an Ingress hangs in `pending` with no useful error.

## EKS

- **Kubernetes 1.35** — one minor behind newest; inside standard support without chasing the edge.
- **`authentication_mode = "API"`**, not the legacy `aws-auth` ConfigMap — a well-known way to lock yourself out with no recovery short of AWS support.
- **`bootstrap_cluster_creator_admin_permissions = false`.** With `true`, cluster-admin goes to whoever ran the first apply — implicit, and different on a laptop than in CI. Every admin is an explicit access entry, merged from a variable **and** the identity running the apply, so a CI apply cannot lock itself out of the cluster it just created.
- **Prefix delegation on the VPC CNI** raises pods-per-node from 35 to 110.
- **`t3.large` x 2, on-demand.** The observability stack alone wants ~4.5 GB. Spot saves ~70% but a reclaimed node mid-interview is not worth it.
- **KMS envelope encryption** for etcd secrets, using the same platform CMK.

## RDS

- **`manage_master_user_password = true`.** RDS generates and rotates the credential in Secrets Manager; Terraform never sees it, so it cannot leak through state or a CI log. Trade-off: the secret ARN changes on every rebuild, which is why `scripts/sync-values.sh` exists.
- **`rds.force_ssl = 1`** in the parameter group. Without it, `sslmode=require` on the client is a promise the server never checks.
- **Security group references the EKS cluster SG**, not a CIDR. Under the VPC CNI pods share the node's ENI and its security groups, so this is what actually grants pod-to-database access — and it stays correct when subnets change.

## IRSA

- **One reusable module, one role per workload.** The load balancer controller role is genuinely broad (it creates ALBs, target groups, security groups) and uses AWS's own vendored policy rather than a hand-rolled one that looks narrower without being so. The secret-reader roles read exactly one Secrets Manager ARN each.
- **`kms:ViaService` condition** on the decrypt permission: the identity can use the platform key only through Secrets Manager, so it cannot decrypt Terraform state with the same key.
- **The application's own service account carries no AWS identity.** A separate service account exists purely to be impersonated by External Secrets. A compromised app pod cannot reach Secrets Manager even though a secret-reading identity sits in the same namespace.
- **`for_each` over variables, never over a resource.** `for_each` keys must be known at plan time. This exact bug appeared four times — access entries, IRSA policy attachments, security group rules — always invisible locally, where the resource already existed in state, and always breaking a clean apply.

## Application

- **`/healthz` does not touch the database; `/readyz` does.** If liveness checked the database, an outage would restart every replica — a recoverable dependency failure turned into a self-inflicted one.
- **Graceful shutdown fails readiness, waits 5 s, then drains.** On pod deletion SIGTERM and endpoint removal race; removal has to reach `kube-proxy` on every node and the ALB target group. A server that exits immediately is still receiving traffic when it closes its socket.
- **Migration failure is not fatal.** The pod comes up unready and recovers. Exiting would give CrashLoopBackOff with exponential backoff — a 30-second database blip becomes minutes of downtime.
- **Metrics labelled by route pattern, never raw path.** Raw paths are a cardinality explosion that takes Prometheus down.
- **Histogram buckets straddle 250 ms** so the latency SLO is counted at a real bucket boundary rather than interpolated across one.
- **Traces on the OTel SDK, metrics on the Prometheus client.** OTel's HTTP semantic conventions would rename `http_requests_total`, rewriting every recording rule and burn-rate alert as a side effect of a plumbing change. Exemplars link the two.
- **Distroless static, non-root, read-only root filesystem.** No shell, no package manager. Exec-form `ENTRYPOINT` so the binary is PID 1 and gets SIGTERM directly — shell form would route it to `/bin/sh`, which distroless does not have.

## Observability

- **One OTel Collector, DaemonSet, doing logs and traces.** Not the agent-plus-gateway topology: that earns its cost once you need tail sampling, cross-node aggregation or a single vendor egress. DaemonSet is not optional for the log half regardless — the `filelog` receiver reads `/var/log/pods` off the host.
- **Traces take a node-local hop** to the collector on the pod's own node via `hostPort`, so losing one node's collector affects only that node's pods.
- **No metrics pipeline in the collector** — set to `null` explicitly, because a Helm map merge cannot delete a key by omitting it. Prometheus scrapes the application directly.
- **Loki `SingleBinary`, filesystem storage.** Distributed mode is right at scale and roughly 6x the footprint two `t3.large` nodes have spare.
- **Tempo's metrics generator draws the service graph** from real parent-child span relationships, so it cannot drift from reality the way a hand-maintained diagram does. Needs `enableRemoteWriteReceiver` on Prometheus; without it the generator retries silently and nothing ever appears.
- **Exemplars are the link between all three signals**, and every hop has to be right: OpenMetrics on `/metrics` (the classic text format has no syntax for exemplars), `exemplar-storage` on Prometheus, `exemplarTraceIdDestinations` on the Grafana datasource, and `"exemplar": true` on the dashboard target. Miss any one and there is no error anywhere — the link just does not exist.
- **SLO burn-rate alerts, not `CPU > 80%`.** Four thresholds from the Google SRE workbook. Burn rate 1 means the 30-day error budget lasts exactly 30 days; 14.4 means it is gone in two days. Each alert pairs a long window (proves the burn is real) with a short one (confirms it is still happening), so it resolves when the incident does instead of hanging for hours. Recording rules compute the ratio once per window instead of inline in six alert expressions.
- **Control-plane scrape jobs disabled.** EKS does not expose `kube-controller-manager`, `kube-scheduler`, `etcd` or `kube-proxy`; each left enabled fires a permanent "target down", which trains people to ignore alerts.
- **Alertmanager routes on `severity`, not on alert name**, so a new alert inherits the right urgency without touching the routing tree.

## GitOps

- **Argo CD is the only thing Terraform installs in the cluster.** Everything else is an Argo `Application`. Adding a component is a pull request, not a Terraform change.
- **Rejected: Amazon EKS Capabilities** (managed Argo CD, GA Nov 2025). It bills separately, infrastructure in AWS-owned accounts cannot be shown live, and self-hosting is the daily-driver tool. In production the managed option is probably the better default — it removes upgrade, HA and CVE burden for the GitOps engine itself.
- **Multi-source Applications** (`ref: values`), because a single-source Application resolves `valueFiles` relative to its own path and refuses to escape it.
- **Sync waves 0/1/2.** External Secrets must exist before the application, or its `ExternalSecret` has no controller and the pod starts without a credential. The collector must exist before the application, or the first spans go nowhere.
- **`ServerSideApply`** for kube-prometheus-stack: its CRDs exceed the annotation size limit that client-side apply uses to store last-applied state.
- **`terraform state rm` before `destroy`** for the Argo CD release. The Helm provider authenticates through the cluster endpoint, which stops answering once the cluster is gone. Accurate rather than evasive: destroying the cluster destroys what is inside it anyway.

## CI/CD

- **Three workflows split by trigger, not by tool.** `environment` is the only one that mutates infrastructure — push to `main`, or `workflow_dispatch` with a typed `up`/`down` confirmation, behind a GitHub Environment with a required reviewer.
- **`app-release` never touches the cluster.** It ends with a Git commit. No kubeconfig, no cluster token, no cluster role exists in it.
- **Security gates ordered so failures are cheap.** Trivy against source first (a bad `go.mod` fails in 30 s pointing at the dependency, not after a 5-minute build pointing at a layer digest) → build locally with `push: false` → Trivy against the image → SBOM → push → cosign sign.
- **Keyless signing.** The identity is the workflow's OIDC token, certified by Fulcio and recorded in Rekor. No private key to store, rotate or leak. Verification is not yet enforced in-cluster; a Kyverno `verifyImages` policy is the next step and the reason to sign now.
- **Deploy by digest, not tag.** A signature covers a digest. ECR tags are immutable here too, but the digest is what cosign actually signed.

---

## Bugs found and fixed

The part worth the most airtime: these are what separate reading LLM output from owning it.

- **PostgreSQL CTE snapshot.** All sub-statements of a `WITH` clause see the same snapshot, so a sibling `SELECT` cannot see the row a data-modifying CTE just inserted. The visit counter was permanently one behind. Reproduced in `psql`, fixed by counting pre-insert and adding the new row explicitly.
- **OTLP endpoint semantics — traces silently never left the pod.** `OTEL_EXPORTER_OTLP_ENDPOINT` is a *base* URL per the OTLP spec; the SDK's `WithEndpointURL` treats its argument as the *complete* traces endpoint and, given no path, sets the path to `/`. The collector serves only `/v1/traces`, so every export was answered with a 404. Nothing looked wrong: the app was `Healthy`, logged `"tracing":true`, generated trace IDs, returned them to callers, and attached them to exemplars Prometheus dutifully stored — all pointing at traces that did not exist. Found by reading the collector's own `otelcol_receiver_accepted_spans`, which did not exist at all, meaning zero spans had ever arrived.
- **…and the reason nobody noticed.** The SDK reports async failures through its global error handler, which writes to Go's standard `log` package, which `slog.SetDefault` routes to the JSON handler at **INFO**. A completely dead trace pipeline read as one unremarkable info line. Now routed through `slog` at ERROR with a stable message.
- **The collector was not being scraped.** `serviceMonitor.enabled: true` is accepted and silently does nothing in `daemonset` mode — the chart only renders a ServiceMonitor alongside a Service, and renders neither unless `service.enabled` is set. Replaced with a PodMonitor, which is the right shape anyway: a Service in front of a DaemonSet scrapes one arbitrary collector per interval.
- **Grafana's Tempo datasource pointed at port 3100** — Loki's port, not open on the Tempo service at all. Tempo's query API is 3200.
- **Log-to-trace correlation matched a label that does not exist.** The `filelog` receiver ships each container line as an opaque string after CRI parsing, so the application's JSON stays in the body and `trace_id` is neither a label nor structured metadata. Confirmed against the Loki store. Changed to a regex derived field over the line.
- **external-dns cannot own a zone apex record.** Its ownership TXT is named by prefixing the record type onto the first label, so `grafana.incode-demo.grandemeks.tech` becomes `cname-grafana.incode-demo…` (inside the zone, fine) but the apex becomes `cname-incode-demo.grandemeks.tech` — a *sibling* under the registrar-hosted parent, outside the delegated zone, dropped by `domainFilters`. external-dns therefore created the apex A/AAAA and silently skipped their ownership record, after which it no longer recognised them as its own and would never correct them. So after a rebuild the apex kept pointing at the previous ALB and the hostname stopped resolving, while the logs said "All records are already up to date" every minute. Fixed with `txtPrefix: "%{record_type}-."` — the trailing period makes the ownership record a *subdomain* instead of a sibling.
- **Grafana's admin password was regenerated on every sync.** With `adminPassword` unset the chart calls `randAlphaNum`, which returns a new value per render, and Argo renders every sync. The Secret was rewritten each time, the pod template's checksum over it restarted Grafana each time, and Grafana — which keeps its admin password in its own database and will not overwrite an existing admin user from the environment — went on accepting only the password from first install. Nobody could log in, and Grafana's own sidecars were answered 401 on the provisioning reload API. Now sourced from Secrets Manager through External Secrets, exactly like the database credential.
- **Two OTel version-coupling failures.** `semconv.DeploymentEnvironmentName` did not exist in the pinned semconv version, then `resource.Merge` failed at startup on a schema-URL conflict between `resource.Default()` and the semconv package. Fixed by writing attribute keys as literal strings, decoupling from convention-version churn.
- **GitHub's OIDC `sub` claim carries numeric IDs on this account** — `repo:owner@<id>/repo@<id>:ref:…`, not the documented name form every published example shows. STS never says which claim failed, so the only reliable method was printing the actual token from a workflow and diffing it against the trust policy. Binding to the ID is the stronger form: a repo can be renamed or recreated under the same name; an ID is never reissued.
- **GitHub rewrites `sub` when a job declares an `environment:`.** Adding the approval gate — a security improvement — broke authentication, because the token then presents `environment:dev` instead of `ref:refs/heads/main`.
- **Helm templating vs Grafana legends.** Grafana's `{{route}}` uses the same delimiters as Helm. Dashboard JSON is loaded with `.Files.Get` rather than inlined, because everything under `templates/` is template source — including inside what YAML would call a comment.

## Known rough edges — be ready for these

- **A pull request can assume the Terraform admin role.** The bootstrap trust policy trusts `pull_request`, and for `pull_request` events GitHub runs the workflow file *from the head branch* — so a PR could add a step that applies or destroys infrastructure. The real control is branch protection plus the required reviewer on the `environment` job, not the workflow split. Worth stating plainly rather than claiming the split is structural.
- **`terraform fmt -check -recursive` never sees `terraform/modules/`**, because CI runs it per-stack with a `working-directory`. Most of the code lives in `modules/`.
- **No Go job in CI.** `pr-checks` triggers on `app/**` but never builds, vets or tests the Go code.
- **`teardown.sh` does not touch Route53.** Record cleanup depends on external-dns still running when the Ingress is deleted.
- **Single AZ RDS, single NAT, no cluster autoscaler, no pod-level network policy.** All deliberate cost choices for a demo environment; all things I would change for production.

## What production would add

Tail sampling in a gateway collector, and `TraceIDRatioBased` instead of `AlwaysSample`. Thanos or Mimir for long-term metrics on S3. Multi-AZ RDS with automated failover testing. Kyverno enforcing image signatures. Cluster autoscaler or Karpenter. Network policies. A real Alertmanager receiver instead of two null ones. Grafana behind SSO instead of a local admin.
