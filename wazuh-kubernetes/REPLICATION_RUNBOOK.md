# Wazuh on GKE — Replication Runbook

How to redeploy this exact Wazuh stack (manager + indexer + dashboard) onto a **new**
GKE cluster/project. For the history of *why* things ended up this way, see
`DEPLOYMENT_LOG.md` — this file is just the repeatable procedure.

## What this deploys
- `wazuh/wazuh-manager:4.14.5` — 1 master + 2 workers (StatefulSets)
- `wazuh/wazuh-indexer:4.14.5` — 3-node cluster (StatefulSet)
- `wazuh/wazuh-dashboard:4.14.5` — 1 replica (Deployment)
- All in a dedicated `wazuh` namespace, storage via a GKE PD-backed StorageClass
- Fronted by **either** a dedicated Traefik (`envs/dev`-style) **or** the target
  cluster's existing Istio ingress gateway (`envs/prod`-style) — see "Ingress choice" below

Pinned to `v4.14.5` deliberately — **do not** switch to the community repo's `main`
branch without checking Docker Hub first; `main` tracks an unreleased pre-release
version (e.g. `5.1.0-alpha0`) whose images don't exist yet, which will leave every pod
stuck in `ImagePullBackOff`.

## Prerequisites on the target cluster
1. `gcloud container clusters get-credentials <cluster> --region <region> --project <project>`
2. Confirm a GKE PD storage class is available (`kubectl get sc` — any project's default
   `standard-rwo`, using `pd.csi.storage.gke.io`, works with `envs/dev/storage-class.yaml`
   / `envs/prod/storage-class.yaml` unchanged).
3. Check for taints on the target node pool(s): `kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints`.
4. Decide the ingress approach (see below) based on what's already running on the cluster.

## Step 1 — Pick and adapt an overlay
Copy `envs/dev/` or `envs/prod/` as a starting point (whichever is closer to the new
target) into a new folder if this is a genuinely new environment, or edit in place if
reusing one of the existing two. Things that need to change per-cluster:

- **`storage-class.yaml`**: provisioner/type only need touching if the target isn't GKE
  (the current `pd.csi.storage.gke.io` / `pd-balanced` works on any GKE cluster as-is).
- **Node pinning**: if the target has multiple node pools and you want Wazuh isolated to
  one, add/adjust the 4 `*-node-selector.yaml` patch files
  (`cloud.google.com/gke-nodepool: <pool-name>`) and reference them in
  `kustomization.yml`. If there's only one pool, skip this entirely (no patch needed).
- **Resource sizing** (`*-resources.yaml`): defaults (~4.7 CPU / 6.5Gi requests, 180Gi
  storage total) fit comfortably on modest node pools; only adjust for very small
  clusters or intentionally heavier indexer/manager sizing.

## Step 2 — Certificates
The repo's own `wazuh/certs/{indexer_cluster,dashboard_http}/generate_certs.sh` scripts
generate everything needed locally (self-signed root CA + per-component certs) — no
external dependency, no download required:
```bash
cd wazuh-kubernetes/wazuh/certs
bash indexer_cluster/generate_certs.sh
bash dashboard_http/generate_certs.sh
```
These `.pem` files are gitignored — regenerate them fresh for each new deployment target
(or reuse existing ones if redeploying to a cluster that already trusts them). Kustomize's
`secretGenerator` in `wazuh/kustomization.yml` reads them directly at apply time.

## Step 3 — Ingress choice
Decide based on what's already running on the target cluster:

**Option A — Dedicated Traefik** (used for the dev cluster). Good default when the
cluster has no ingress controller, or its existing one is heavily shared by other teams
and you don't want to touch it at all.
- Vendor `traefik/` (CRDs + runtime) from the community clone (or an existing
  `envs/dev`-style deployment) into the repo.
- `kubectl apply -f traefik/crd/kubernetes-crd-definition-v1.yml && kubectl apply -k traefik/runtime/`
- Add 4 `IngressRouteTCP` objects (dashboard TLS-passthrough on `websecure`/443, plus
  1514/1515/55000 raw TCP) — see `envs/dev/traefik-routes.yaml` for the exact pattern.
- Patch `dashboard`/`wazuh`/`wazuh-workers` Services to `ClusterIP` (no longer need their
  own public LoadBalancers).
- Result: exactly 1 new external IP for the whole stack.

**Option B — Reuse an existing Istio ingress gateway** (used for `zoop-ops`). Good when
the cluster already runs Istio **and** that gateway is lightly used or unused — check
first with `kubectl get gateway,virtualservice -A` (if it's near-zero, low risk; if it's
heavily used by many other teams, prefer Option A instead, or a dedicated second Istio
gateway to avoid touching shared config at all).
- Add a `networking.istio.io` `Gateway` (namespace `wazuh`, `selector: {istio: ingressgateway}`)
  with 4 servers: port 443 `TLS`/`PASSTHROUGH` matched to your chosen hostname, plus
  1514/1515/55000 as plain `TCP` — see `envs/prod/istio-gateway.yaml` for the exact
  pattern, including the 4 matching `VirtualService` objects.
- The shared `istio-ingressgateway` Service in `istio-system` needs 3 new ports added
  (1514/1515/55000 — it typically only ships 80/443/15021 by default). This is **outside**
  the kustomize overlay (pre-existing resource, not part of the resource graph) — always
  fetch the live Service, append new port entries, and apply back, never regenerate the
  whole object from scratch (preserves any existing customization). Check first that no
  other `Gateway`/`VirtualService` already depends on this Service before adding ports.
- Result: 0 new external IPs (reuses what's already there).

In both cases, **skip a trusted TLS cert initially** — deploy with the self-signed certs
from Step 2 first (works immediately, browser will just warn), verify everything end to
end, then add a trusted cert as a separate follow-up (Step 5) once you're confident the
core deployment works.

## Step 4 — Deploy
```bash
kubectl apply -k envs/<your-overlay>/
```
Watch for readiness:
```bash
kubectl get pods -n wazuh -w
```
Expect 7 pods total: `wazuh-indexer-{0,1,2}`, `wazuh-manager-master-0`,
`wazuh-manager-worker-{0,1}`, `wazuh-dashboard-<hash>`. A `Pending`/`FailedScheduling`
indexer pod for a few tens of seconds is normal on a busy/small pool — the GKE cluster
autoscaler will add a node automatically if enabled; only investigate further if a pod
stays stuck for several minutes.

## Step 5 — Verify
```bash
# All pods Running, PVCs Bound
kubectl get pods,pvc -n wazuh

# Indexer cluster health (expect "green", 3 nodes)
kubectl exec -n wazuh wazuh-indexer-0 -- curl -sk -u admin:SecretPassword https://localhost:9200/_cluster/health

# End-to-end through the ingress (before DNS is even set up, using --resolve / raw IP):
curl -sk -o /dev/null -w "%{http_code}\n" --resolve <your-hostname>:443:<gateway-ip> https://<your-hostname>/   # expect 302
curl -sk --resolve <your-hostname>:55000:<gateway-ip> https://<your-hostname>:55000/                            # expect a real 401 JSON, not a connection error
nc -zv <gateway-ip> 1514
nc -zv <gateway-ip> 1515
```

## Step 6 — DNS
Create/repoint a Cloudflare A record for your chosen hostname → the ingress's external
IP. **Must be DNS-only (grey cloud), not Proxied** — Cloudflare's standard proxy can't
carry the raw TCP ports (1514/1515/55000 aren't HTTP traffic and aren't on its supported
proxied-port list); only DNS-only mode works for this whole setup.

## Step 7 (optional, later) — Trusted TLS cert
Requires a working cert-manager `ClusterIssuer` for DNS-01 via Cloudflare in the target
project (check `kubectl get clusterissuer` first — may already exist and be reusable, or
may need a new Cloudflare API token + `ClusterIssuer`, following whatever per-zone-token
convention the org already uses — check existing tokens in Cloudflare's API Tokens list
before creating a new one blindly).
- **If using Traefik**: request a `cert-manager.io` `Certificate`, add a `ServersTransport`
  (`insecureSkipVerify: true`) so Traefik can still reach the dashboard pod's own
  self-signed backend, and replace the dashboard's `IngressRouteTCP` (passthrough) with an
  `IngressRoute` (`Host()`-matched, real TLS termination) — see the dev cluster's
  `wazuh-dashboard-cert.yaml` / `dashboard-backend-transport.yaml` for the pattern
  (currently only exists in git history / DEPLOYMENT_LOG.md, since it was removed when
  the dev deployment was torn down).
- **If using Istio**: confirmed working end-to-end on `zoop-ops` — see
  `envs/prod/wazuh-dashboard-tls.yaml` (`ClusterIssuer` + `Certificate`) and
  `envs/prod/istio-gateway.yaml` for the exact live pattern:
  1. **The `Certificate`'s Secret must be created in the gateway workload's own namespace**
     (typically `istio-system`), **not** the app namespace — Istio's SDS lookup for a
     Gateway's `credentialName` reads from the proxy's own namespace, regardless of where
     the `Gateway`/`VirtualService` objects live. Check the gateway's ServiceAccount already
     has an SDS `Role`/`RoleBinding` granting `secrets` read there (standard on most Istio
     ingressgateway installs — `kubectl get role,rolebinding -n istio-system | grep sds`).
  2. Switch the Gateway's dashboard server from `protocol: TLS` / `tls.mode: PASSTHROUGH` to
     `protocol: HTTPS` / `tls.mode: SIMPLE` + `credentialName: <secret-name>`.
  3. Change the matching `VirtualService` from a `tls:`-block (SNI-matched) to a plain
     `http:`-block route — the Gateway now decrypts before routing, so there's no more SNI
     to match on.
  4. Add a `DestinationRule` (`trafficPolicy.tls: {mode: SIMPLE, insecureSkipVerify: true}`)
     for the dashboard Service — Envoy needs this to re-encrypt (and skip verifying) when
     forwarding to the dashboard pod's still-self-signed backend cert. This is the Istio
     equivalent of Traefik's `ServersTransport`.
  5. A dedicated `ClusterIssuer` per zone/token (rather than reusing/widening an existing
     one) keeps this fully isolated from whatever else that cert-manager install already
     issues — cheap to create, zero risk to other certs.

## Known gotchas checklist
- [ ] Confirm image tags are for a **released** Wazuh version before deploying (check
      Docker Hub, not just the repo's `VERSION.json` — pre-release branches ship
      manifests referencing images that don't exist yet).
- [ ] If using `IngressRouteTCP`/`IngressRoute` for the same name, remember `kubectl apply`
      does **not** delete an old object of a different Kind with the same name — clean up
      orphans manually when switching between them.
- [ ] The `indexer`/raw-DB-API Service should stay `ClusterIP`, never a public
      LoadBalancer — nothing outside the cluster needs to call it directly.
- [ ] Cloudflare DNS record must be **DNS-only**, not Proxied, for the raw TCP ports to work.
- [ ] Default credentials (`admin`/`SecretPassword` for the dashboard,
      `wazuh-wui`/`MyS3cr37P450r.*-` for the API) come straight from the vendored repo's
      secret manifests — rotate them before this is anything more than a throwaway
      environment.
