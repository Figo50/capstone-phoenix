# Cost

Region `eu-north-1` (Stockholm), on-demand pricing, 730 hours per month. Figures are estimates,
rounded to cents; check the AWS pricing pages and the Cost Explorer before quoting them.

## Monthly itemized cost

| Item | Spec | Qty | $/mo |
|---|---|---:|---:|
| control-plane VM | t3.small, 2 vCPU / 2 GiB ($0.0216/hr) | 1 | 15.77 |
| worker VMs | t3.small, 2 vCPU / 2 GiB ($0.0216/hr) | 2 | 31.54 |
| public IPv4 addresses | $0.005/hr each, one per node | 3 | 10.95 |
| block storage (root volumes, PVC) | 8 GiB default root volume per node, gp3 (about $0.08/GB-mo). The Postgres PVC lives on a worker's root disk (`local-path`), so there is no separate volume | 24 GiB | ~1.90 |
| object storage (Terraform state) | S3, a few KB | 1 | ~0.00 |
| DNS / domain | `nip.io` wildcard DNS, free. Certificates from Let's Encrypt, free | 1 | 0.00 |
| load balancer | none. Traefik (k3s built-in) serves ports 80/443 on the nodes | 0 | 0.00 |
| **Total** | | | **~60** |

Assumptions: the default 8 GiB root volume is used (no size override in `infra/terraform/main.tf`),
and data transfer is small enough to fall inside the free allowance.

## Compared to the single-server Compose + Portainer deploy

- That stack cost roughly **$20/mo**, assuming one t3.small ($15.77), one public IPv4 ($3.65) and
  one 8 GiB volume (~$0.64). Adjust this if the old server was a different size.
- This cluster costs roughly **$60/mo**, about three times as much.
- **What the extra spend buys:**
  - **Node-failure tolerance.** Backend and frontend run two replicas each, on different nodes. In
    the live drain test, 600 of 600 requests succeeded while a worker was drained.
  - **Zero-downtime deploys.** Rolling updates with `maxUnavailable: 0` and readiness probes replace pods
    without dropped requests, and a PodDisruptionBudget protects them during node drains.
  - **Autoscaling.** An HPA adds backend replicas under load.
  - **Self-healing and GitOps.** Failed pods are restarted and rescheduled automatically, and the
    cluster state is reconciled from Git, so it is reproducible and every change is auditable.
- **When it is not worth it.** For a low-traffic internal tool where a few minutes of downtime during
  a deploy or a server reboot is acceptable, a single server is better value. Note also that the
  database is still a single replica on one node's disk, so this cluster is highly available for the
  stateless tiers only. The cost of true database HA (a replicated Postgres or a managed database)
  is not included above.

## How I'd halve this

Keeping the architecture, the realistic saving is about a third, to roughly **$41/mo**. Run the
node that does not host Postgres on Spot (about $0.008/hr against $0.0216, saving about $10/mo). The
stateless pods tolerate interruption because the other worker keeps serving, but Postgres and the
control plane must stay on-demand. Then put the two remaining always-on nodes under a one-year
Compute Savings Plan, which saves roughly 25-30% on those nodes (about $9/mo). Reaching half, about
**$30/mo**, means dropping to a control plane plus one worker (two nodes on a savings plan). That
removes one public IPv4 and one volume but also removes the second node that the failover demo drains,
so it trades away the high availability this cluster exists to show. I would not make that cut
for a service that needs to stay up.
