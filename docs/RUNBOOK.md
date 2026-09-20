# Runbook: TaskApp on k3s

A teammate should be able to rebuild and operate the cluster from this file alone.

**Topology:** three AWS EC2 `t3.small` nodes in `eu-north-1a`: one k3s control plane and two workers.
Postgres runs as a single-replica StatefulSet on one worker. Backend and frontend run as
Deployments with 2 replicas each, spread across nodes. Argo CD owns everything under `manifests/app/`.

---

## 1. Provision from zero

### 1.1 Infrastructure (Terraform)

```bash
cd infra/terraform
terraform init      # state lives in the S3 backend configured in backend.tf
terraform apply
terraform output    # note the public/private IPs of the three nodes
```

Before applying, check `variables.tf`:

- the IP allow-list variable defaults to the original operator's address. Set it to your own `/32`,
  or SSH and the API will be unreachable.
- `~/.ssh/capstone_key.pub` must exist (or override the public-key path variable).

State is remote (S3). Local `terraform.tfstate*` files are git-ignored and must never be committed.

### 1.2 Cluster (Ansible, idempotent)

Put the IPs from `terraform output` into `infra/ansible/hosts.ini`, then:

```bash
cd infra/ansible
ansible-playbook -i hosts.ini setup-k3s.yml
```

Re-running is safe. It installs k3s on the control plane and joins both workers.

### 1.3 Kubeconfig

If the playbook did not already fetch it (see `infra/ansible/README.md`), copy
`/etc/rancher/k3s/k3s.yaml` from the control plane, replace `127.0.0.1` with the control plane's
public IP, then:

```bash
export KUBECONFIG=./kubeconfig
kubectl get nodes        # expect 3 nodes, all Ready
```

### 1.4 Platform components

k3s ships Traefik (ingress), metrics-server, flannel and the network policy controller. Two things
are installed by hand:

```bash
# cert-manager (Let's Encrypt certificates)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.yaml

# Argo CD
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install.yaml

kubectl get pods -n cert-manager -n argocd   # wait until everything is Running
```

The `ClusterIssuer` (`manifests/app/30-cluster-issuer.yaml`) is synced by Argo CD.

### 1.5 Secret (created by hand, never in Git)

The Secret is deliberately outside the path Argo CD syncs, so it must exist before the first sync:

```bash
kubectl apply -f manifests/app/00-namespace.yaml
cp manifests/templates/02-secret.example.yaml /tmp/secret.yaml
# edit /tmp/secret.yaml: replace every placeholder with a real value
kubectl apply -f /tmp/secret.yaml
rm /tmp/secret.yaml
```

### 1.6 GitOps takes over

```bash
kubectl apply -f gitops/taskapp-app.yaml
kubectl get applications -n argocd     # expect Synced / Healthy
```

Argo CD applies the ConfigMap, Postgres, migration Job, backend, frontend, ingress, HPA, PDB and
NetworkPolicies from `manifests/app/`.

### 1.7 Hostname and TLS

The site is served at `https://taskapp.<control-plane-public-ip>.nip.io/`. The hostname embeds the
control plane's public IP. If that IP changes (for example after a stop/start without an Elastic IP),
update the host in `manifests/app/23-ingress.yaml`, commit, and cert-manager issues a new certificate.

### 1.8 Verify

```bash
kubectl get nodes
kubectl get pods -n taskapp -o wide       # backend/frontend on different nodes, all 1/1
kubectl get certificate -n taskapp        # READY=True
curl -vI https://taskapp.<ip>.nip.io/     # issuer: Let's Encrypt
./scripts/verify-ingress.sh
```

---

## 2. Day-2 operations

Prefer a Git commit for every change so Argo CD stays the source of truth. A manual `kubectl` change
is reverted by self-heal or shows as OutOfSync.

- **Scale a tier.** Backend replicas are owned by the HPA. Change `minReplicas`/`maxReplicas` in
  `manifests/app/24-hpa.yaml`. Frontend replicas are set in `manifests/app/21-frontend.yaml`. Commit and push.
- **Deploy a new version.** Change the pinned image tag (a commit SHA, never `:latest`) in
  `20-backend.yaml` or `21-frontend.yaml`, commit and push. RollingUpdate with `maxUnavailable: 0`
  and readiness probes keep the old pods serving until the new ones are ready
  (proof: `docs/EVIDENCE/zero-downtime.log`).
- **Roll back a bad deploy.**
  ```bash
  git revert HEAD --no-edit && git push
  kubectl get pods -n taskapp -w
  ```
  Because of `maxUnavailable: 0`, a bad image never replaces the old pods, so the site stays up
  while you revert.
- **Run a new migration safely.** Migrations run in a one-off Job (`22-migration-job.yaml`), never
  in the app entrypoint, so replicas cannot race on `alembic upgrade head`. A Job's pod template is
  immutable. To run a new migration:
  1. Take a database backup (section 3, "A bad migration").
  2. Bump the image tag in the Job manifest and delete the old Job:
     `kubectl delete job taskapp-migrate -n taskapp`.
  3. Commit and push, then sync in Argo CD so the Job is recreated.
  4. Check `kubectl logs job/taskapp-migrate -n taskapp`.
- **Rotate a secret.** Edit the Secret and re-apply it, then restart the consumers:
  ```bash
  kubectl apply -f <edited-secret.yaml>
  kubectl rollout restart deployment/taskapp-backend -n taskapp
  ```
  Note: the Postgres password is set when the data directory is first initialised. Changing it in
  the Secret does **not** change the existing database user's password. Also run
  `ALTER USER ... PASSWORD '...'` inside Postgres.

---

## 3. Failure recovery

### A worker node is drained or dies

- **What happens.** Pods on the node are evicted (drain) or become NotReady and are evicted after
  the default 5-minute toleration (node loss). The scheduler recreates them on the remaining node.
  Backend and frontend each keep one pod on the other worker, so requests continue to be served.
- **Observed recovery.** Live drain of `ip-10-0-1-200`: 600 of 600 requests returned HTTP 200 and
  the replacement pods were 1/1 in about two minutes
  (`docs/EVIDENCE/failover-*.txt`, `failover-requests.log`).
- **The live-demo command.**
  ```bash
  kubectl drain ip-10-0-1-200 --ignore-daemonsets --delete-emptydir-data --timeout=120s
  kubectl get pods -n taskapp -o wide
  kubectl uncordon ip-10-0-1-200        # afterwards; pods do not move back on their own
  ```
- **Never drain the Postgres node or the control plane** (see the limitations below).
- If `kubectl` times out (`i/o timeout`), repeat the command. Drain and uncordon are safe to repeat.

### A backend pod crashloops

```bash
kubectl get pods -n taskapp
kubectl logs <pod> -n taskapp --previous
kubectl describe pod <pod> -n taskapp        # events: probe failures, OOMKilled, image pull
kubectl get events -n taskapp --sort-by=.lastTimestamp
```

If it followed a deploy, roll back with `git revert HEAD --no-edit && git push`. The readiness
probe and `maxUnavailable: 0` keep the previous pods serving in the meantime.

### A bad migration

There is no automated database backup (a CronJob to object storage is future work). Take a manual
dump **before** any migration:

```bash
kubectl exec -n taskapp postgres-0 -- sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' > backup-$(date +%F).sql
```

To recover, either step the schema back:

```bash
kubectl exec -n taskapp deploy/taskapp-backend -- alembic downgrade -1
```

or restore the dump into Postgres with `psql`, after dropping and recreating the database.

### Postgres pod is deleted or rescheduled

```bash
kubectl delete pod postgres-0 -n taskapp
kubectl get pods -n taskapp -w        # StatefulSet recreates it on the same node
```

The same PVC re-attaches and the data is intact (`docs/EVIDENCE/postgres-data-survival.txt`).
See the limitation below for what this does **not** protect against.

---

## 4. Known limitations

### Postgres is a single replica on node-local storage

The storage class is k3s `local-path` (reclaim policy `Delete`). The PVC is a directory on one
worker's disk, so the Postgres pod is pinned to that node.

- Deleting the pod or restarting the node is safe.
- If that node is drained, `postgres-0` stays Pending until the node is back. The app loses its
  database for that time.
- If that node's disk is lost, so is the data. Deleting the PVC also deletes the data.
- Improvements: scheduled `pg_dump` to object storage, the EBS CSI driver for volumes that can
  move between nodes, or a replicated Postgres or managed database.

### Control plane capacity (found during failover drain)

The control plane is a t3.small (2 vCPU, about 2 GB RAM) running k3s, Argo CD, cert-manager and
Traefik, at about 77-83% memory at rest. Draining a worker evicted about 9 pods onto it, and the API
server and Traefik stopped answering until the instance was rebooted. Data was unaffected (Postgres
runs on a different node). Mitigations: a larger control-plane instance, an Elastic IP so a
stop/start cannot change the public address, and draining only the app pods. Evidence of the first
attempt is kept in `docs/EVIDENCE/incident-attempt1-*.txt`.

---

## 5. Container hardening (securityContext)

- Backend: runs as non-root (uid 10001), no privilege escalation, all capabilities dropped, seccomp RuntimeDefault.
- Frontend (nginx): image starts as root, so runAsNonRoot is not possible. No privilege escalation,
  all capabilities dropped except CHOWN, SETGID, SETUID, NET_BIND_SERVICE, seccomp RuntimeDefault.
- Postgres: image starts as root and steps down to its own user. No privilege escalation, seccomp RuntimeDefault.
  Capabilities not dropped and non-root not forced, to avoid permission errors on the existing data volume.
- readOnlyRootFilesystem was not enabled: the apps write to disk (nginx cache and pid, Postgres data).
  Enabling it needs emptyDir mounts and is listed as follow-up work.
- The migration Job is not yet hardened: a Job's pod template is immutable after creation, so it needs a recreate or a sync hook.

## 6. Secrets handling

The taskapp Secret is created by hand and never stored in Git. Only a template with placeholder
values lives in the repo, at `manifests/templates/02-secret.example.yaml`, outside the path Argo CD
syncs, so a sync can never overwrite the real Secret. Create the real Secret from the template
before the first Argo CD sync (section 1.5). Trade-off: the manual step keeps credentials out of Git.
Stretch option: Sealed Secrets removes the manual step.

## 7. NetworkPolicy enforcement (CNI)

k3s ships flannel (VXLAN) for pod networking and embeds kube-router's network policy controller,
so NetworkPolicies are enforced without installing a separate CNI. Enforcement was verified:
an unlabelled pod cannot reach Postgres (`docs/EVIDENCE/netpol-tests.txt`), while the backend and
the migration Job can. Policies: default-deny ingress, Traefik to frontend/backend, frontend to
backend, backend and migration Job to Postgres.
