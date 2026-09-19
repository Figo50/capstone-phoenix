# Capstone Progress Tracker
(against README.md §4 and §5 — not a guess, copied straight from the rubric)

## Milestone 1 — Fix hard-constraint violation (blocks grade cap at 60)
- [ ] 6443 no longer open to 0.0.0.0/0 in Terraform
- [ ] kubectl still reachable after the fix (SSH tunnel / restricted CIDR / VPN — pick one)
- [ ] Terraform modularized: network / security_group / compute
- [ ] Remote state (S3 + DynamoDB lock), no local tfstate in git
- [ ] Variables for AMI/instance type/region — no hardcoded values

## Milestone 2 — Namespace, config, secrets
- [ ] Dedicated namespace for the app (not `default`)
- [ ] ConfigMap for non-secret env
- [ ] Secret for secret env — NOT committed in plaintext

## Milestone 3 — Postgres
- [ ] StatefulSet + headless Service + PVC on real storage class
- [ ] Evidence: data survives a Pod delete

## Milestone 4 — Real app images + migration Job
- [ ] Backend: real Flask app (or GHCR image if already built), pinned tag
- [ ] Frontend: real React build (or GHCR image if already built), pinned tag
- [ ] Migration as a Job, not in entrypoint

## Milestone 5 — Hardening (Core, non-negotiable)
- [ ] liveness + readiness + startup probes, every workload
- [ ] resources.requests + limits, every container
- [ ] 2+ replicas/tier, topologySpreadConstraints across nodes
- [ ] RollingUpdate maxUnavailable: 0, proven zero-downtime
- [ ] cert-manager + Let's Encrypt, REAL domain, valid public cert

## Milestone 6 — GitOps (required, not optional)
- [ ] Argo CD installed
- [ ] App synced from this repo
- [ ] Live commit -> auto-sync demo captured

## Milestone 7 — Advanced (pick >= 3)
- [ ] HPA (with load-test evidence)
- [ ] NetworkPolicy (default-deny + explicit allows)
- [ ] PDB + graceful shutdown
- [ ] Observability (metrics-server + dashboard)
- [ ] securityContext hardening

## Milestone 8 — Docs + Evidence
- [ ] ARCHITECTURE.md filled in properly
- [ ] RUNBOOK.md filled in properly
- [ ] COST.md filled in properly
- [ ] EVIDENCE/ has proof for every box above
- [ ] Failover demo rehearsed

---
Already done, verified with real evidence:
- [x] Ingress routing /, /api -> correct services, browser-confirmed
      (docs/EVIDENCE/ingress-verification.txt)
- [x] 3-node k3s cluster up, kubectl reachable

## HANDOFF NOTE (for continuing in a new chat)
Repo: ~/capstone-phoenix (WSL, Windows user Jeff)
Cluster: 3-node k3s on AWS eu-north-1, control plane 16.16.213.192
kubectl: export KUBECONFIG=~/k3s.yaml (also in ~/.bashrc and ~/.profile)
Admin IP allowed for SSH/6443: check with curl -s https://checkip.amazonaws.com,
  compare to admin_cidr in infra/terraform/variables.tf - update+reapply if changed.
Real app images (verified against GHCR directly, guide's tags were WRONG):
  backend:  ghcr.io/ts-a-devops/taskapp-backend:5d6b8fc
  frontend: ghcr.io/ts-a-devops/taskapp-frontend:26da2b0
Working test: curl -H "Host: taskapp.local" http://16.16.213.192/api/health
Known flaky: kubectl over the public IP occasionally times out (~17s stalls) -
  not a real problem, just retry.
Currently starting: Milestone 5, TLS via cert-manager + nip.io domain
  (taskapp.16.16.213.192.nip.io), ClusterIssuer needs a REAL email, not example.com.
