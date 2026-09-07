# Decisions

Design decisions for the eks-platform reference environment: what was chosen, what was considered instead, and why. This is the presentation version — see the interview walkthrough for live-demo talking points.

## Terraform: two stacks, not one

`terraform/bootstrap` holds what must survive a teardown: state bucket, KMS key, DNS zone, ECR repository, ACM certificate, GitHub OIDC roles. `terraform/envs/dev` holds what gets destroyed nightly: VPC, EKS, RDS. Separate state files in one S3 bucket — a `destroy` in one can never reach the other.

**Cost of the persistent layer:** ~$1.50/month.

## State: S3 with native locking

Terraform 1.11+ locks via the state object itself (`use_lockfile = true`), removing the DynamoDB table every older guide prescribes.

**`prevent_destroy` on the state bucket.** Everything else is reproducible from code; state history is not.

## Network: `/20` subnets, mapped by AZ

The AWS VPC CNI gives every *pod* a real VPC IP, so pods consume subnet space — a `/24` runs out around the third deployment. Subnets are `for_each` maps keyed by AZ name, not a list with `count`: a list reorders on any AZ change and Terraform destroys and recreates the subnet — and everything inside it.

**One NAT gateway, not one per AZ** (`single_nat_gateway` flag). Stated cost decision: ~$0.045/h + $0.045/GB. Alternatives considered: `fck-nat` on `t4g.nano` (~10x cheaper, AMI becomes your responsibility), VPC interface endpoints with no NAT at all (best security, traffic never leaves AWS, but five endpoints cost the same as the NAT over a short run).

**Subnet tags `kubernetes.io/role/elb` / `internal-elb`.** The AWS Load Balancer Controller discovers subnets by these tags. Without them, an Ingress hangs in `pending` with no useful error.

## EKS: hand-written, not the community module

3000+ lines of a module I didn't write works against the brief's requirement to explain and modify every part of the code live. Hand-written is ~200 lines I can defend line by line.

**Kubernetes 1.35** — one minor behind newest, inside standard support without chasing the edge.

**`authentication_mode = "API"`**, not the legacy `aws-auth` ConfigMap — a notorious way to lock yourself out of your own cluster with no recovery short of AWS support. Access is now real, Terraform-managed AWS resources.

**`bootstrap_cluster_creator_admin_permissions = false`.** With `true`, cluster-admin goes to whoever ran the first apply — implicit, and different between a laptop and CI. Every administrator is an explicit `aws_eks_access_entry`, merged from a variable **and** the identity currently running the apply (`data.aws_iam_session_context`), so a CI apply can never lock itself out of the cluster it just created.

**Prefix delegation on the VPC CNI** raises pods-per-node from 35 to 110 — otherwise the ENI/secondary-IP model caps pods far below what memory could run.

**`t3.large` × 2, on-demand.** The observability stack alone needs ~4.5 GB; `t3.medium` leaves no headroom. Spot would save ~70% but a reclaimed node mid-interview isn't worth it.

## RDS: managed password, forced TLS

**`manage_master_user_password = true`.** RDS generates and rotates the credential in Secrets Manager; Terraform never sees it, so it can't leak through state or a CI log. Trade-off: the secret ARN changes on every environment rebuild (see `scripts/sync-values.sh`).

**`rds.force_ssl = 1`** in the parameter group — without it, `sslmode=require` on the client is a promise the server never verifies.

**Security group references the EKS cluster SG**, not a CIDR. Under the AWS VPC CNI, pods share the node's ENI and its security groups — so this is what actually grants pod-to-database access, and it stays correct when subnets change.

## IRSA: one reusable module, least privilege where it counts

Every AWS-facing workload gets its own role and its own trust condition pinned to one namespace/service-account pair — never a shared identity.

**Two roles show the contrast on purpose.** The Load Balancer Controller role is genuinely broad (it creates ALBs, target groups, security groups) and uses AWS's own vendored IAM policy rather than a hand-rolled one that would look narrower without being so. The `demo-app-secrets` role reads exactly one Secrets Manager ARN, decrypts with one KMS key, and nothing else — scoped with a `kms:ViaService` condition so it can't touch the same key's other uses (state, ECR).

**`for_each` over variables, never over a resource.** `for_each` keys must be known at plan time; a resource like `aws_eks_access_entry` doesn't exist yet on a from-scratch apply. This exact class of bug appeared four times across the codebase — access entries, IRSA policy attachments, security group rules — always invisible locally (where the resource already existed in state) and always breaking on a clean `apply`.

## Application: Go, instrumented with help from an LLM

Not a Go developer. Specified the behavior — which endpoints, why liveness must not touch the database, which metrics with which labels, how graceful shutdown must be sequenced — and used an LLM for the syntax. Every design decision below is defensible; the CTE bug is evidence of that.

**`/healthz` doesn't touch the database; `/readyz` does.** If liveness checked the database, an outage would restart every replica — a recoverable dependency failure converted into a self-inflicted one.

**Graceful shutdown waits 5 seconds before draining.** On pod deletion, SIGTERM and Service-endpoint removal race. Removal has to propagate to `kube-proxy` on every node and to the ALB target group — seconds, not instant. A server that exits immediately still receives traffic when it closes its socket. Sequence: fail readiness → wait → drain.

**Metrics labelled by route pattern, never raw path** — raw paths are a cardinality explosion that takes Prometheus down.

**Histogram buckets straddle 250ms** so the latency SLO is counted at an exact bucket boundary, not interpolated.

**PostgreSQL CTE snapshot bug — found and fixed.** All sub-statements of a `WITH` clause run against the same snapshot; a sibling `SELECT` can't see a row a data-modifying CTE just inserted. The visit counter reported one behind forever. Reproduced in `psql`, fixed by counting pre-insert and adding the new row explicitly. This is the clearest evidence of actually reviewing LLM-generated code rather than trusting it.

**Distroless static base, non-root, read-only root filesystem.** No shell, no package manager. `readOnlyRootFilesystem` needs no `emptyDir` because a static Go binary writes nothing. Exec-form `ENTRYPOINT` so the binary is PID 1 and receives SIGTERM directly — shell form would route it to `/bin/sh`, which distroless doesn't have.

**Traces via OpenTelemetry SDK; metrics stay on the Prometheus client.** OTel's HTTP semantic conventions rename `http_requests_total` to `http_server_request_duration_seconds` — switching would rewrite every SLO recording rule and burn-rate alert as a side effect of a plumbing change. Traces go through OTel because Prometheus doesn't do traces; exemplars link the two.

**Exemplars require `EnableOpenMetrics: true` on the `/metrics` handler.** The classic Prometheus text format has no syntax for exemplars — they're computed, stored, then silently dropped on the way out without this flag.

**Two production bugs in the OTel setup, both from version coupling.** `semconv.DeploymentEnvironmentName` didn't exist in the pinned semconv version (the attribute was renamed between convention versions). Then `resource.Merge` failed at startup with a schema-URL conflict between `resource.Default()` and the semconv package — different versions, same failure family. Fixed by writing attribute keys as literal strings (`"deployment.environment"`) instead of through semconv helpers, decoupling from convention-version churn entirely.

## Helm chart: hand-written, not Kustomize

Reversed an earlier plan. Chosen because it's the tool used daily and must be defended live, and because the rest of the platform (kube-prometheus-stack, Loki, External Secrets) already arrives as Helm charts — one mechanism instead of two.

**`values.yaml` + `values-dev.yaml`**, chart separate from environment values. Slightly redundant with one environment, but it's the parameterization the brief asks for.

**Selector labels exclude version and chart.** A Deployment's selector is immutable after creation; any label that changes between releases must never appear in it.

**Deploy by digest when available.** A digest is byte-exact and verifiable against a signature. ECR is `IMMUTABLE` tags too, but the digest is what Cosign actually signs.

**Grafana dashboard JSON loaded via `.Files.Get`, not inlined.** Grafana's legend format (`{{route}}`) uses the same delimiters as Helm templating. Inlining the JSON makes Helm try to execute those as template functions — including inside comments, since everything under `templates/` is template source regardless of what YAML would treat as a comment.

## ArgoCD: the one thing Terraform installs into the cluster

Terraform installs exactly two things via `helm_release`: Argo CD itself, and a single root `Application` (app-of-apps). Everything else — the load balancer controller, External Secrets, the observability stack, the application — is an Argo `Application` discovered from `argocd/argo-manifests/`. Adding a component is a pull request, not a Terraform change.

**Alternative considered and rejected: Amazon EKS Capabilities** (GA Nov 2025), fully managed Argo CD in AWS-owned infrastructure. Rejected here because it bills separately, because infrastructure running outside this account can't be demonstrated live, and because self-hosting is the daily-driver tool. In production, the managed capability would be the better default — it removes upgrade/HA/CVE burden for the GitOps engine itself.

**Multi-source Applications** (`ref: values`) because the chart and its environment values live in different directories — a single-source Application resolves `valueFiles` relative to its own path and refuses to escape it.

**Sync waves**, not arbitrary ordering: infra controllers at wave 0–1, the application at wave 2. External Secrets and the load balancer controller must exist before anything that depends on them syncs.

**`helm_release` for Argo CD cannot be destroyed cleanly once the cluster is gone** — the Helm provider authenticates via the cluster endpoint, which no longer answers. `terraform state rm` before `terraform destroy` is the fix: accurate rather than evasive, since destroying the cluster destroys everything inside it anyway.

## Observability: Loki, Tempo, one OTel Collector

**Single OTel Collector in DaemonSet mode**, doing both logs and traces — not the agent-plus-gateway topology used at scale. That shape earns its cost once you need tail sampling, cross-node aggregation, or one egress point to a vendor; here it would be two hops and roughly double the memory for two nodes and one application. DaemonSet isn't optional for the log half regardless: the `filelog` receiver reads `/var/log/pods` off the host, so it has to run on every host whose logs matter.

**No metrics pipeline in the collector.** Deliberate — see the app-instrumentation note above. Prometheus scrapes the application directly via ServiceMonitor.

**Loki: `SingleBinary` mode, filesystem storage.** The default distributed mode (separate read/write/backend StatefulSets against S3) is correct at scale and roughly 6x the footprint of what two `t3.large` nodes have spare.

**Tempo's metrics generator writes a service graph** derived from actual parent-child span relationships — discovered from traffic, so it can't drift from reality the way a hand-drawn diagram can. Requires `enableRemoteWriteReceiver: true` on the Prometheus side; without it, the generator retries silently and no error appears anywhere — it just never shows up.

**Exemplars are the link between all three signals.** A histogram observation carries a trace ID; the Grafana Loki datasource has a `derivedFields` regex on `trace_id` that renders it as a link. The demo path: burn-rate alert fires → dashboard shows the latency spike → click the exemplar → trace opens → "Logs for this span" → the pod's log lines in that exact window. One minute, zero typed queries.

**SLO burn-rate alerts, not `CPU > 80%`.** Four thresholds from the Google SRE workbook (14.4x/1h, 6x/6h, 3x/1d, 1x/3d) pair a long window (proves the burn is real) with a short one (confirms it's still happening), so the alert resolves when the incident does instead of hanging for hours after. Recording rules compute the error ratio once per window rather than inline in every alert expression — cheaper, and readable when an alert fires at 3am.

**`kubeControllerManager` / `kubeScheduler` / `kubeEtcd` / `kubeProxy` disabled** in kube-prometheus-stack. EKS doesn't expose the control plane, so each left enabled produces a permanently-firing "target down" alert — training the team to ignore alerts, which is worse than not having them.

## CI/CD: three workflows, split by trigger not by tool

**`pr-checks.yml`** has no apply path and no `pull_request` trigger anywhere near `environment.yml`. That's structural, not an `if:` condition someone could get wrong — a mistake in a conditional could let a pull request apply infrastructure; a missing trigger cannot.

**`environment.yml`** is the only workflow that changes infrastructure — `push` to `main` (reviewed changes) or manual `workflow_dispatch` with a typed confirmation (`up`/`down`). Runs behind a GitHub Environment with a required reviewer.

**`app-release.yml` never touches the cluster.** It ends with a Git commit; Argo CD reconciles from there. No kubeconfig, no cluster token, no cluster role exists in this workflow — if compromised, it can push one image to one ECR repository and nothing else.

**GitHub's OIDC `sub` claim carries numeric IDs, not names**, on this account: `repo:owner@<id>/repo@<id>:ref:...` rather than the documented `repo:owner/repo:...`. Every published example shows the name-only form. Diagnosed by printing the actual token from a workflow and comparing it against the live trust policy — STS deliberately never says which claim failed, so that's the only reliable method. Binding to the numeric ID is the stronger form: a repo can be renamed or recreated under the same name; an ID is never reissued.

**GitHub rewrites the `sub` claim when a job declares an `environment:`.** A job with an approval gate presents `environment:dev` in its token instead of `ref:refs/heads/main` — so adding the approval gate (a security improvement) broke authentication the first time, in a way the error message gave no hint about.

## Security gate: ordered so failures are cheap

1. **Trivy dependency scan** runs against source, before the build — a vulnerable `go.mod` entry fails in 30 seconds pointing at the dependency, not after a 5-minute build pointing at a layer digest.
2. **Build locally** (`push: false, load: true`) so the image can be scanned before it's published — pushing first would make a vulnerable image already pullable.
3. **Trivy image scan** before `docker push`.
4. **SBOM** (SPDX) generated and attached as a Cosign attestation — not useful today, useful the morning a new CVE lands and the question is which images contain the affected package.
5. **Cosign keyless signing** — identity is the workflow's own OIDC token, certified by Fulcio, recorded in Rekor. No private key to store, rotate, or leak.

**A real gate caught a real CVE on first use**: two CRITICAL findings in `pgx` (fixed upstream, one version bump). `ignore-unfixed: true` already skips CVEs with no available patch — these had one, so the gate correctly blocked the build rather than being disabled to make it pass.

## Teardown: not a bare `terraform destroy`

Deleting an EKS cluster tears down the control plane but doesn't drain what's running on it — the load balancer controller and CSI driver lose their API server mid-reconcile. PersistentVolumeClaims become orphaned EBS volumes; Ingresses become orphaned load balancers and security groups; those security groups then block VPC deletion entirely. AWS ships a standalone cleanup script alongside its own EKS reference architecture for exactly this reason — this isn't a workaround, it's an acknowledged gap between "deklarative infrastructure" and "deklarative cluster."

**Two-phase destroy, deliberately using `-target`.** Phase 1 destroys `module.eks` and `module.database` only. Phase 2 sweeps AWS resources the load balancer controller created, identified by tag (`elbv2.k8s.aws/cluster`) since they're not in Terraform state and have no predictable name. Phase 3 destroys everything else. `-target` is normally a smell; here it's the point — the sweep is only meaningful once the controller is provably dead, and that ordering can't be expressed in the dependency graph because the dependency runs *inside* a resource Terraform is destroying.

**Nine fixes, each found by an actual failed teardown, not by reasoning about it in advance:**

1. **PVCs before workloads is backwards.** A PVC carries a `pvc-protection` finalizer released only once no pod mounts it — deleting claims while Prometheus/Grafana still run hangs until timeout and achieves nothing. Fix: delete workloads, wait for pods to terminate, *then* delete PVCs.
2. **No wait after deleting Ingresses.** The controller reconciles asynchronously; `kubectl delete` returning isn't the same as the ALB being gone. Moving on early left an ALB holding ENIs through a 13-minute `destroy` that then failed with a `DependencyViolation` naming an ENI and explaining nothing.
3. **Shared ALB group + one-at-a-time Ingress deletion causes the controller to recreate the ALB.** With `group.name` shared between `demo-app` and Grafana, deleting one Ingress leaves the group non-empty — the controller reconciles the remaining member by recreating the load balancer (and a fresh security group) *after* the sweep already ran. Fix: delete all Ingresses in one call.
4. **Argo Application finalizers block forever if the controller goes first.** `resources-finalizer.argocd.argoproj.io` exists so deleting an Application also deletes what it deployed. During teardown that inverts: no controller left to run the finalizer, object stuck in `Terminating`, taking the owning `helm_release` down with it. Fix: strip finalizers before deleting anything.
5. **`helm_release` for Argo CD can't be destroyed once the cluster is gone** — see the ArgoCD section above. Fix: `terraform state rm` first.
6. **No `terraform init` before `destroy` in CI.** Trivial, but a fresh runner has no `.terraform/` directory and the first CI-run teardown failed on this alone.
7. **`cluster_admin_principal_arns` lived only in a gitignored `terraform.tfvars`.** A CI apply saw an empty list and correctly removed the access entry it couldn't see in configuration — silently revoking the operator's own cluster access mid-session, surfacing later as an unexplained `Unauthorized`. Fix: a real IAM ARN isn't a secret; it now has a non-empty default in code, merged with the identity currently running the apply.
8. **PVC deletion needs `--wait=false` + poll, not `--wait=true`.** A blocking delete against a claim whose finalizer hasn't cleared hangs for the full timeout and *reports failure* even though deletion is progressing normally.
9. **Verification must query the AWS API, not trust the destroy output.** Terraform reporting success only means it deleted what it knew about — the script's final phase checks nine resource categories independently (clusters, VPCs, NAT gateways, EIPs, load balancers, target groups, volumes, RDS instances, leftover security groups).

**Result:** two consecutive full `destroy → apply` cycles through the CI pipeline, unattended, with all nine categories verified empty both times. This is the strongest evidence in the whole project that "Terraform code is the source of truth, not the running environment" — the brief's own phrase — actually holds.

## What would change in production

- Multi-AZ RDS (currently single-AZ — the single largest deliberate availability compromise, made explicit as a variable)
- One NAT gateway per AZ instead of one shared
- Tail sampling in a gateway-tier OTel Collector instead of always-on sampling
- A permissions boundary + Access-Analyzer-generated policy for the Terraform CI role, replacing `AdministratorAccess`
- Application-level database user instead of connecting as the RDS master user
- Grafana admin credential synced from Secrets Manager instead of chart-generated
- Kyverno `verifyImages` policy enforcing the Cosign signature already being produced