
## Container hardening (securityContext)

- Backend: runs as non-root (uid 10001), no privilege escalation, all capabilities dropped, seccomp RuntimeDefault.
- Frontend (nginx): image starts as root, so runAsNonRoot is not possible. No privilege escalation,
  all capabilities dropped except CHOWN, SETGID, SETUID, NET_BIND_SERVICE, seccomp RuntimeDefault.
- Postgres: image starts as root and steps down to its own user. No privilege escalation, seccomp RuntimeDefault.
  Capabilities not dropped and non-root not forced, to avoid permission errors on the existing data volume.
- readOnlyRootFilesystem was not enabled: the apps write to disk (nginx cache and pid, Postgres data).
  Enabling it needs emptyDir mounts and is listed as follow-up work.
- The migration Job is not yet hardened: a Job's pod template is immutable after creation, so it needs a recreate or a sync hook.

## Secrets handling

The taskapp Secret is created by hand and never stored in Git. Only a template with placeholder
values lives in the repo, at `manifests/templates/02-secret.example.yaml`, outside the path Argo CD
syncs, so a sync can never overwrite the real Secret. Create the real Secret from the template
before the first Argo CD sync. Trade-off: the manual step keeps credentials out of Git.
Stretch option: Sealed Secrets removes the manual step.

## NetworkPolicy enforcement (CNI)

k3s ships flannel (VXLAN) for pod networking and embeds kube-router's network policy controller,
so NetworkPolicies are enforced without installing a separate CNI. Enforcement was verified:
an unlabelled pod cannot reach Postgres (docs/EVIDENCE/netpol-tests.txt), while the backend and
the migration Job can. Policies: default-deny ingress, Traefik to frontend/backend, frontend to
backend, backend and migration Job to Postgres.

## Known limitation: control plane capacity (found during failover drain)

The control plane is a t3.small (2 vCPU, ~2 GB RAM) running k3s, Argo CD, cert-manager and Traefik,
at about 77-83% memory at rest. Draining a worker evicted ~9 pods onto it; the API server and
Traefik stopped answering until the instance was rebooted. Data was unaffected (Postgres runs on a
different node). Mitigations: larger control-plane instance, Elastic IP so a stop/start cannot change
the public address, and draining only the app pods. Evidence of the first attempt is kept in
docs/EVIDENCE/incident-attempt1-*.txt.
