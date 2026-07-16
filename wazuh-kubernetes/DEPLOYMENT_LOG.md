# Wazuh on GKE — Deployment Log

Running journal of the work to deploy a full Wazuh stack (manager + indexer + dashboard)
onto the `development-k8s-cluster` GKE cluster (project `zoop-one-development`), pinned to
the `dev-stage-spot-3` node pool, in a dedicated `wazuh` namespace.

---

## 2026-07-15

### GCP / GKE connection
- Connected `gcloud` to project `zoop-one-development` (previously pointed at `zoop-mymotor`).
- Found one GKE cluster: `development-k8s-cluster` (asia-south1, 9 nodes, RUNNING). Fetched
  kubeconfig credentials, verified `kubectl` connectivity.
- Audited the `dev-stage-spot-3` node pool specifically (as requested): 3 nodes,
  `n2d-custom-16-40960` (16 vCPU / 40GB each), autoscaling enabled up to 6 nodes, no taints.
  Noted the pool is labeled `on-demand` in its resourceLabels despite being named "spot" —
  flagged as a possible naming/cost mismatch, not something we've acted on.
  CPU/mem usage at the time: ~5% CPU, ~45% memory used; ~60-67% of allocatable already
  *requested* by existing workloads (headroom exists but isn't huge).

### Repo discovery
- User pointed to a local clone of the official `wazuh-kubernetes` repo (community repo,
  `main` branch). Reviewed its structure: Kustomize-based, `envs/eks` + `envs/local-env`
  overlays, full stack (manager StatefulSets + indexer StatefulSet + dashboard Deployment).
  Gave an initial plan to adapt the `eks` overlay for GKE.
- User then revealed the **actual org repo is `wazuh-infra`** (`wazuh-kubernetes` was just a
  reference/community clone). Explored `wazuh-infra` and found:
  - `wazuh/helm-chart/` — a custom Helm chart that deploys **only the Wazuh manager** to GKE.
  - `wazuh/pipeline/{dev,prod}/Jenkinsfile` — already wired for
    `GCP_PROJECT=zoop-one-development` / `GKE_CLUSTER=development-k8s-cluster` (dev) and
    `zoop-production` / `zoop-one-production-cluster` (prod).
  - `production/docker-compose.yml` — indexer + dashboard + IRIS run on a separate VM, not
    on Kubernetes at all. Manager (on GKE) ships data to this VM stack.
  - `wazuh/jumpcloud-scripts/` — agent rollout to ~200 endpoints via JumpCloud, pointed at
    the manager's GKE LoadBalancer IP.
  - Flagged: the chart's `NOTES.txt` incorrectly implies a dashboard is reachable at
    port 55000 (that's just the raw API) — no dashboard container exists in this chart.
    Also flagged a hardcoded demo admin password in `values.yaml`.

### Architecture decision
- Asked the user: keep the org's existing "manager-only on GKE + indexer/dashboard on a VM"
  pattern, or run the **full stack on GKE** as a self-contained dev environment.
  → User chose **full stack on GKE**.

### Plan A (superseded): extend the Helm chart
- Entered plan mode, designed a plan to add indexer/dashboard templates directly into
  `wazuh/helm-chart/` (new StatefulSet/Deployment templates, a Helm-hook cert-generation
  Job, a selector-label bugfix, nodeSelector wiring). Plan was approved and implementation
  began (fixed a real bug in `_helpers.tpl` where all components would have shared the same
  pod-selector labels).
- **User then proposed a cleaner alternative** mid-implementation: instead of hand-rolling
  indexer/dashboard support in Helm, vendor the official community `wazuh-kubernetes` repo
  (which already has working indexer clustering/TLS/dashboard wiring) directly into
  `wazuh-infra`, under a new `wazuh-kubernetes/` folder with `envs/dev` and `envs/prod`.
  This is lower-risk than hand-rolling OpenSearch cluster discovery/TLS config, and leaves
  the existing manager-only Helm chart untouched.

### Plan B (current): vendor community repo into `wazuh-infra/wazuh-kubernetes/`
- Re-entered plan mode, wrote a new plan around vendoring `wazuh/`, `traefik/`, `tools/` from
  the community repo, with GKE-specific `envs/dev`/`envs/prod` overlays.
- Confirmed with the user: full vendor copy, both `dev` and `prod` scaffolded (prod not
  deployed, just structured for later). Plan approved.

---

## 2026-07-16

### Implementation of Plan B
- Copied `wazuh/`, `traefik/`, `tools/` from the community repo's `main` branch into
  `wazuh-infra/wazuh-kubernetes/`.
- Fixed `wazuh/base/ingressRoute-tcp-dashboard.yaml`: AWS-ELB FQDN placeholder →
  `HostSNI(\`*\`)` wildcard (GKE LoadBalancers get an IP, not a stable hostname).
- Built `envs/dev/` overlay (started from a copy of the community repo's `envs/eks`, then
  rewrote the AWS-specific parts — confirmed with the user first that this doesn't mean
  we're deploying to AWS, just reusing that overlay's shape as a template):
  - `storage-class.yaml`: `kubernetes.io/aws-ebs` (gp2) → `pd.csi.storage.gke.io`
    (pd-balanced), keeping the class name `wazuh-storage` unchanged so nothing else needs
    touching.
  - Added 4 new node-selector patch files (`indexer-node-selector.yaml`,
    `wazuh-master-node-selector.yaml`, `wazuh-worker-node-selector.yaml`,
    `dashboard-node-selector.yaml`) pinning every workload to
    `cloud.google.com/gke-nodepool: dev-stage-spot-3`. Wired into `kustomization.yml`.
  - Validated with `kubectl kustomize .` — failed as expected on missing (not-yet-generated,
    gitignored) cert files, confirming the resource/patch structure itself resolves fine.
- Scaffolded `envs/prod/` as a copy of `envs/dev/`, then **disabled** the node-selector
  patches there with a TODO comment (the `dev-stage-spot-3` pool doesn't exist on the prod
  cluster — leaving it wired in would make prod pods stick in `Pending`).
- Added `pipeline/dev/Jenkinsfile` (mirrors the existing `wazuh/pipeline/dev/Jenkinsfile`
  pattern: auth → deploy Traefik → generate certs → `kubectl apply -k envs/dev/`). Added an
  idempotency guard on the cert-generation stage per user request (skip regeneration if
  `config/root-ca/certs/root-ca.pem` already exists in the workspace, so Kustomize's
  content-hashed secret names don't change — avoiding unnecessary pod restarts on every
  pipeline run). Also added `pipeline/prod/Jenkinsfile` (scaffold, approval-gated, matching
  the org's existing prod pipeline pattern).

### Deployment attempt — problems found
1. Applied Traefik CRDs + runtime to the cluster — **succeeded** (`traefik` namespace,
   Deployment, LoadBalancer Service all created).
2. Attempted to download `wazuh-certs-tool.sh` / `config.yml` for version `5.1.0` (per the
   community repo's `VERSION.json`, which reads `"stage": "alpha0"`) —
   **both downloads came back as 111-byte S3 "Access Denied" XML pages**, not real files.
3. Investigated further: **`wazuh/wazuh-manager:5.1.0` (and indexer/dashboard) do not exist
   on Docker Hub** (confirmed 404). Root cause: the community repo's `main` branch is an
   unreleased `5.1.0-alpha0` pre-release — none of its referenced images are published yet.
   Deploying as-is would leave every pod stuck in `ImagePullBackOff` indefinitely.
4. Checked available released versions: `v4.14.5` tag exists, and its manager/indexer/
   dashboard images **are** confirmed present on Docker Hub — and it's the same version
   already running in `production/docker-compose.yml`, so using it keeps the whole org on
   one consistent Wazuh version.
5. **However**, `v4.14.5`'s manifests are structurally different from `main`, not just a
   version bump:
   - No Traefik at all — exposes dashboard/API/registration via a plain `LoadBalancer`
     Service instead of an ingress controller.
   - Indexer config is a mounted ConfigMap (static YAML), not `main`'s env-var-driven
     OpenSearch config (`discovery.seed_hosts`, `NODES_DN`, etc. via container env).
   - Different service/secret/volume naming throughout.
   - Ships its own self-contained cert-generation scripts
     (`wazuh/certs/{indexer_cluster,dashboard_http}/generate_certs.sh`) instead of
     depending on downloading `wazuh-certs-tool.sh` from `packages.wazuh.com` — this also
     sidesteps the failed-download problem from step 2.
   - Mixing `main`'s env-var-driven manifests with a `4.14.5` image was judged too risky:
     the older image's entrypoint may not understand those env vars at all, so the indexer
     cluster could come up **silently misconfigured** (e.g. not actually clustering) rather
     than failing loudly.
6. Presented the choice to the user: keep `main`'s manifests and just retag the images
   (less rework, riskier), or redo the vendor/adaptation work against the real `v4.14.5`
   tag (more rework, correct). **User chose: switch to `v4.14.5`.**

### Re-vendoring against `v4.14.5` and first successful deploy
- Removed the now-unneeded `main`-based Traefik deployment (CRDs + namespace + Deployment +
  Service) from the cluster.
- Checked out the `v4.14.5` tag into a scratch git worktree (read-only reference, original
  community clone untouched) and fully re-explored its structure: no Traefik (exposes
  `dashboard`/`wazuh`/`wazuh-workers` directly as public `LoadBalancer` Services instead),
  indexer/manager config via mounted ConfigMaps, self-contained openssl-based
  `generate_certs.sh` scripts (no `packages.wazuh.com` dependency).
- Replaced the `main`-based `wazuh/` and `tools/` copy in `wazuh-infra/wazuh-kubernetes/`
  with the `v4.14.5` versions. Rebuilt `envs/dev/` (and re-scaffolded `envs/prod/`) against
  the new file layout: GKE storage class fix (`pd.csi.storage.gke.io`, `pd-balanced`),
  4 node-selector patches pinning every workload to `dev-stage-spot-3`, and a new patch
  converting the `indexer` Service from a public `LoadBalancer` to `ClusterIP` (its raw
  admin-level REST API on 9200 doesn't need to be internet-facing — only the in-cluster
  manager/dashboard call it).
- Updated both Jenkinsfiles: dropped the Traefik stage, switched cert generation to the
  `generate_certs.sh` scripts, updated the access-info stage.
- Generated certs locally, validated the full overlay render (`kubectl kustomize .`),
  confirmed nodeSelector/storage-class/service-type patches all applied correctly in the
  rendered manifest before touching the cluster.
- Deployed: `kubectl apply -k envs/dev/`. All 7 pods (indexer x3, manager-master x1,
  manager-worker x2, dashboard x1) came up `Running` on `dev-stage-spot-3` nodes only,
  PVCs bound, indexer cluster reported `green` with all 3 nodes joined.

### Consolidating 3 LoadBalancers down to 1
- After the first successful deploy, `dashboard`/`wazuh`/`wazuh-workers` were still public
  `LoadBalancer` Services (3 separate external IPs) — raised as a cost concern.
- Explored consolidating onto the cluster's existing **shared Istio ingress gateway**
  (`istio-ingressgateway` in `istio-system`) instead of adding a new dedicated ingress.
  Investigated thoroughly: confirmed the `ingress-nginx` namespace some earlier exploration
  had flagged is actually dead (empty, no pods, orphaned `IngressClass`, nothing depends on
  it) — the real active shared ingress is Istio, used by ~130 `VirtualService`s across
  `develop`/`staging`/`claims-dev`/`qsight` for real product traffic (billing, auth, esign,
  digilocker, etc.). Confirmed the shared gateway Service/Deployment carries
  `app.kubernetes.io/managed-by: Helm` labels but has **no** matching Helm release secret in
  the cluster (installed via `helm template`/`istioctl`, not tracked `helm install`) — and no
  `helm` CLI available locally to introspect it further. Traced a possible source-of-truth
  to the user's own `zoop-istio-gateway` repo, but that turned out to only contain vendored
  upstream Istio release bundles (per-version `manifest.yaml`/charts/tools), not the actual
  site-specific Gateway/Service customization — so there was no safe, precise place to add
  Wazuh's ports to the shared gateway without risking a silent revert on the next Istio
  upgrade.
- **Decision: defer the shared-Istio-gateway question**, and first do the straightforward
  thing — stand up a **small, dedicated, fully isolated Traefik** just for Wazuh (same
  approach the abandoned `main`-branch attempt used, just re-pointed at `v4.14.5`'s actual
  service names). This doesn't touch Istio or any other team's infrastructure at all.
- Implementation: re-vendored `traefik/` (CRDs + runtime) into `wazuh-infra/wazuh-kubernetes/`.
  Added a 4th Traefik entryPoint (`wazuh-55000`) alongside the original 3
  (`websecure`/443, `wazuh-1514`, `wazuh-1515`) — `v4.14.5`'s `wazuh` Service bundles the API
  (55000) and registration (1515) ports together, unlike the `main`-branch layout. Added 4
  `IngressRouteTCP` objects (`wazuh-dashboard` TLS-passthrough on `websecure`,
  `wazuh-events`→`wazuh-workers:1514`, `wazuh-registration`→`wazuh:1515`,
  `wazuh-api`→`wazuh:55000`) and 3 new patches converting `dashboard`/`wazuh`/`wazuh-workers`
  from `LoadBalancer` to `ClusterIP`. Synced the same files into the `envs/prod` scaffold for
  structural consistency. Updated both Jenkinsfiles with a Traefik-apply stage.
- Applied and verified: zero pod disruption (all 7 Wazuh pods stayed `Running`, 0 restarts,
  same age throughout). All 3 Services now `ClusterIP` (no external IP). Traefik has exactly
  **one** external IP serving all 4 ports. Confirmed end-to-end: dashboard reachable over TLS
  passthrough (HTTP 302), agent ports 1514/1515 accept TCP connections, port 55000 returns a
  real HTTP 401 from the Wazuh API (proving it's actually reaching the manager, not just an
  open port).
- Net result: **3 external IPs → 1**, fully isolated from the shared Istio gateway, no
  dependency on figuring out how that shared infrastructure is managed.

### Open item (deferred, not blocking)
Whether to eventually fold Wazuh's ingress into the shared Istio gateway instead of running
a dedicated Traefik — deferred at the user's request pending a separate conversation about
how that shared gateway's config is actually managed/sourced.

### Trusted TLS cert for the dev dashboard, then full teardown
- Pointed `wazuh.zoop.tools` at Traefik's IP via a Cloudflare DNS A record. First attempt was
  set to **Proxied** (orange cloud) — this broke everything, because Cloudflare's standard
  proxy only forwards HTTP(S) on specific ports and cannot pass through arbitrary raw TCP
  (1514/1515/55000 aren't HTTP at all). Fixed by switching the record to **DNS only** (grey
  cloud), which just resolves straight to the IP — works identically to the raw IP for all
  4 ports.
- Dashboard was reachable but browsers flagged it "Not Secure" — expected, since Traefik was
  doing TLS **passthrough** straight to the dashboard pod's self-signed cert. Found an
  existing, working `letsencrypt-cloudflare` `ClusterIssuer` (cert-manager, real Let's
  Encrypt via Cloudflare DNS-01) already used elsewhere in the project for other
  `*.zoop.id`/`*.zoop.tools`-style domains.
- Getting a trusted cert meant switching **only** the dashboard's route from TCP passthrough
  to real TLS termination at Traefik: added a `cert-manager.io` `Certificate` for
  `wazuh.zoop.tools`, a Traefik `ServersTransport` (`insecureSkipVerify: true`, so Traefik
  can still reach the dashboard pod's own self-signed backend after terminating the real cert
  at the edge), and replaced the `wazuh-dashboard` `IngressRouteTCP` (passthrough) with an
  `IngressRoute` (HTTP-layer, `Host()`-matched, real TLS termination). Caught and fixed an
  important orphan: since `IngressRoute` and `IngressRouteTCP` are different CRD kinds,
  `kubectl apply` doesn't delete the old same-named `IngressRouteTCP` automatically — had to
  delete it explicitly to avoid it shadowing the new route via its `HostSNI(*)` wildcard.
- Hit one real blocker: the DNS-01 challenge failed with "Found no Zones for domain
  `_acme-challenge.wazuh.zoop.tools`" — the Cloudflare API token cert-manager uses didn't
  have `Zone:Read` access to the `zoop.tools` zone. Investigated the account's token
  structure: turned out to be **one dedicated token per zone** (not one shared multi-zone
  token), so the fix was creating a new zone-scoped token (`cert-manager-zoop-tools`)
  rather than widening an existing one — matches the account's existing security
  segmentation instead of fighting it. (This part was left as an action item for the user;
  not completed before the pivot below.)
- **User then decided to tear down the entire dev deployment** — the point all along was to
  validate the approach on dev, then deploy for real on a different cluster the user would
  provide. Deleted: `wazuh` namespace (cascaded all pods/PVCs/services/secrets — PVs
  survived per `reclaimPolicy: Retain`, left `Released`, not cleaned up), `traefik`
  namespace, Traefik's `ClusterRole`/`ClusterRoleBinding`, and all Traefik CRDs (confirmed
  first that nothing else on the cluster used them). The **local git repo/manifests were
  left untouched** — including the generated cert `.pem` files under `wazuh/certs/`, which
  turned out to matter later (see below).

## 2026-07-16 (continued) — real deployment to `zoop-ops`

### New target cluster
User provided the real deployment target: project **`zoop-ops`**, cluster **`zoop-ops`**
(asia-south1, single node pool `ops-pool`, 6× `n2d-custom-4-12288`, no taints). Confirmed
suitable: light existing load (2-6% CPU, 21-49% memory), same GKE storage classes as dev
(`standard-rwo` default, `pd.csi.storage.gke.io`). This cluster already runs `develop` and
`production` namespaces side by side (a shared, multi-purpose "ops" cluster), plus its own
separate `istio-system` and `cert-manager` installs (unrelated to the dev cluster's).

User's decisions for this deployment:
1. No node-pool pinning — only one pool exists, so a `nodeSelector` would be redundant.
2. One single environment, called `prod` (not a separate `ops` overlay) — this finalizes the
   `envs/prod` scaffold that had been sitting unused since the original vendoring work.
3. **Reuse the cluster's existing Istio ingress gateway** instead of a dedicated Traefik.
   Investigated first (same due diligence as the earlier deferred dev-cluster question):
   `zoop-ops`'s `istio-ingressgateway` had **zero** existing `Gateway`/`VirtualService`
   objects — genuinely unused, a completely different risk profile from the dev cluster's
   heavily-shared one (~130 VirtualServices). Still Helm-managed (same theoretical
   "could be reset on upgrade" caveat), but with zero current consumers judged safe to use
   directly rather than standing up a second dedicated ingress.
4. TLS: self-signed passthrough for now (this cluster also has no working Cloudflare
   `ClusterIssuer` yet — only unrelated self-signed issuers for `mw-agent-ns`); trusted cert
   is a deferred follow-up, same as it was for dev.
5. Hostname: reuse `wazuh.zoop.tools` — repoint the (now-dangling, since dev was torn down)
   Cloudflare DNS record to this cluster's ingressgateway IP instead of minting a new name.

### Implementation
- Local cert files under `wazuh/certs/{indexer_cluster,dashboard_http}/*.pem` were still on
  disk from the dev work (only the *cluster-side* Secrets were deleted during teardown, not
  the local files) — reused as-is, no regeneration needed.
- Rebuilt `envs/prod/`: removed the Traefik-era files (`traefik-routes.yaml`,
  `dashboard-backend-transport.yaml`, `wazuh-dashboard-cert.yaml` — not applicable without a
  dedicated Traefik), added `istio-gateway.yaml` (one `networking.istio.io` `Gateway`,
  `selector: {istio: ingressgateway}` matching the existing shared ingressgateway pods, plus
  4 `VirtualService`s: a `tls`-block passthrough route for the dashboard on port 443 matched
  by `sniHosts: ["wazuh.zoop.tools"]`, and 3 plain `tcp`-block routes for 1514/1515/55000).
  Used a specific hostname rather than a wildcard SNI match on purpose, so as not to
  accidentally shadow any other team's future Gateway on this same shared ingressgateway.
- The `istio-ingressgateway` Service in `istio-system` only exposed ports 15021/80/443 —
  needed 3 more (1514/1515/55000) added. This Service is pre-existing shared infrastructure
  outside our own kustomization's resource graph, so it couldn't be reached via a kustomize
  patch — handled as a deliberate, separate, auditable step: fetched the live Service YAML,
  appended the 3 new port entries (preserving the existing 3 untouched), applied back.
  Verified before touching it that zero Gateways/VirtualServices used this Service, so the
  change was risk-free to existing traffic.
- `kubectl apply -k envs/prod/`: created the `wazuh` namespace and everything in it cleanly
  in one shot.
- One transient hiccup during rollout: `wazuh-indexer-1` briefly sat in `Pending` /
  `FailedScheduling` ("Insufficient memory... Insufficient cpu") because the 6 existing
  nodes were fully packed at that moment. The cluster autoscaler handled it automatically —
  scaled `ops-pool` up by one node in `asia-south1-c`, pod scheduled ~30s later and proceeded
  normally. Not a configuration problem, just the cluster right-sizing itself.
- Also saw brief `istiod` warnings ("listener missed network filter", "no virtual service
  bound to gateway") in the ~1 second window between the `Gateway` and its 4
  `VirtualService`s landing — resolved on their own once all 4 were applied; confirmed via
  fresh `istiod` logs showing clean `LDS` pushes with `resources:4` and no further warnings.

### Result
All 7 pods `Running` (indexer 3/3 joined, `green`), all 6 PVCs `Bound`, spread across 3 of
the cluster's nodes (autoscaled from 6 to 7 during rollout). Verified all 4 ports end-to-end
through the Istio gateway's existing external IP using `curl --resolve`/`nc` (before asking
for the DNS change): dashboard `302`, API real `401` JSON from the actual manager, 1514/1515
accepting TCP connections — identical responses to what dev produced.

Updated `pipeline/prod/Jenkinsfile`: fixed `GCP_PROJECT`/`GKE_CLUSTER` (were placeholders,
now `zoop-ops`/`zoop-ops`), removed the Traefik-deploy stage, added an idempotent stage that
adds the 3 ports to the shared `istio-ingressgateway` Service only if not already present
(safe to rerun on every pipeline execution), updated the access-info stage to report the
shared gateway's IP and the `wazuh` namespace's `Gateway`/`VirtualService` objects instead of
a dedicated Traefik service.

**Remaining for the user**: repoint the `wazuh.zoop.tools` Cloudflare A record from
`34.47.255.250` (dead) to `34.180.52.91` (this cluster's ingressgateway), DNS-only (not
proxied).

### Deferred (not part of this task)
- ~~Trusted TLS cert for `wazuh.zoop.tools` on `zoop-ops`~~ — done, see below.
- `envs/prod`'s `*-node-selector.yaml` files stay unreferenced/unused — fine as-is for a
  single-pool cluster; would need real pool names filled in if ever pinning matters here.

## 2026-07-16 (continued) — trusted TLS cert on `zoop-ops`

DNS was repointed successfully (`wazuh.zoop.tools` → `34.180.52.91`, DNS-only). Followed up
with the deferred trusted-cert work, same underlying need as the dev cluster but adapted for
Istio termination instead of Traefik.

- Checked first whether the `cert-manager-zoop-tools` Cloudflare token (that we'd asked for
  back when the dev cluster hit the zone-permission error) actually got created — it hadn't;
  the account still only had `cert-manager-zoop-ace` and `cert-manager-carplus-one` (each
  scoped to exactly 1 zone, confirming the account's one-token-per-zone convention). Had the
  user create a new `cert-manager-zoop-tools` token (`Zone:DNS:Edit` + `Zone:Zone:Read`,
  scoped only to `zoop.tools`) and a matching `cloudflare-api-token-zoop-tools` Secret in
  `zoop-ops`'s `cert-manager` namespace (confirmed the user ran this themselves, not pasted
  into chat).
- Confirmed current `kubectl` context before having the user run anything
  (`gke_zoop-ops_asia-south1_zoop-ops`, control-plane IP matching `gcloud container clusters
  list`'s output for `zoop-ops`) — avoided any risk of the secret landing on the wrong
  cluster.
- Built a **dedicated** `ClusterIssuer` (`letsencrypt-cloudflare-zoop-tools`) rather than
  reusing/widening any existing one — zero risk to whatever `cert-manager-zoop-ace`/
  `cert-manager-carplus-one` already issue on this cluster.
- Key difference from the Traefik/dev-cluster approach: the `Certificate`'s resulting Secret
  **must live in `istio-system`**, not `wazuh` — Istio's gateway SDS lookup for
  `credentialName` reads secrets from the gateway workload's own namespace, not wherever the
  `Gateway`/`VirtualService` objects themselves are defined. Confirmed first that the
  existing `istio-ingressgateway-sds` Role/RoleBinding in `istio-system` already grants the
  gateway's ServiceAccount read access there — no extra RBAC needed.
- Switched the `Gateway`'s port-443 server from `protocol: TLS` / `tls.mode: PASSTHROUGH` to
  `protocol: HTTPS` / `tls.mode: SIMPLE` + `credentialName: wazuh-dashboard-tls`. Correspondingly
  changed `wazuh-dashboard-vs` from a `tls:`-block (SNI-matched passthrough) to a plain
  `http:`-block route, since the Gateway now decrypts before routing. Added a new
  `DestinationRule` (`trafficPolicy.tls.mode: SIMPLE`, `insecureSkipVerify: true`) so Envoy
  re-encrypts to the dashboard pod's own self-signed backend after the gateway's real-cert
  termination — the Istio-native equivalent of the `ServersTransport` used for Traefik.
- Applied via `kubectl apply -k envs/prod/`; DNS-01 challenge completed cleanly this time
  (no zone-permission error — new token worked immediately), cert `Ready` in under 2 minutes.
- Verified with a real (non `-k`) `curl`: `SSL certificate verify ok`, `issuer: Let's Encrypt
  CN=YR2`, dashboard responded `HTTP/2 302`. Confirmed the other 3 ports (1514/1515/55000)
  were completely unaffected by this change.
