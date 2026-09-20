
## Container hardening (securityContext)

- Backend: runs as non-root (uid 10001), no privilege escalation, all capabilities dropped, seccomp RuntimeDefault.
- Frontend (nginx): image starts as root, so runAsNonRoot is not possible. No privilege escalation,
  all capabilities dropped except CHOWN, SETGID, SETUID, NET_BIND_SERVICE, seccomp RuntimeDefault.
- Postgres: image starts as root and steps down to its own user. No privilege escalation, seccomp RuntimeDefault.
  Capabilities not dropped and non-root not forced, to avoid permission errors on the existing data volume.
- readOnlyRootFilesystem was not enabled: the apps write to disk (nginx cache and pid, Postgres data).
  Enabling it needs emptyDir mounts and is listed as follow-up work.
- The migration Job is not yet hardened: a Job's pod template is immutable after creation, so it needs a recreate or a sync hook.
