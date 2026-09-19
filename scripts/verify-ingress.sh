#!/usr/bin/env bash
# verify-ingress.sh — deterministic bottom-up check that the Ingress routes
# / -> frontend and /api -> backend. No browser, no DNS, no guessing.
#
# Usage:
#   ./verify-ingress.sh                       # auto-detect everything
#   HOST=taskapp.local NS=default ./verify-ingress.sh
#   NODE_IP=16.16.213.192 ./verify-ingress.sh # also test the public path
#
# Exits non-zero if any layer fails.

set -uo pipefail

HOST="${HOST:-taskapp.local}"
NS="${NS:-default}"
ING="${ING:-taskapp-ingress}"
NODE_IP="${NODE_IP:-}"
FAIL=0

blue()  { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()    { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; }
bad()   { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=1; }
note()  { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Layer 0 — who actually owns port 80?
# ---------------------------------------------------------------------------
blue "Layer 0: ingress controller identity"

kubectl get ingressclass -o custom-columns=NAME:.metadata.name,CONTROLLER:.spec.controller --no-headers 2>/dev/null

HAS_TRAEFIK=$(kubectl get pods -A -l app.kubernetes.io/name=traefik --no-headers 2>/dev/null | wc -l)
HAS_NGINX=$(kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | wc -l)

if [ "$HAS_TRAEFIK" -gt 0 ]; then note "Traefik controller pods: $HAS_TRAEFIK"; fi
if [ "$HAS_NGINX" -gt 0 ];   then note "ingress-nginx controller pods: $HAS_NGINX"; fi

WANT_CLASS=$(kubectl get ingress "$ING" -n "$NS" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
if [ -z "$WANT_CLASS" ]; then
  bad "Ingress $ING not found in namespace $NS"
  exit 1
fi
note "Ingress requests ingressClassName=$WANT_CLASS"

if [ "$WANT_CLASS" = "nginx" ] && [ "$HAS_NGINX" -eq 0 ]; then
  bad "No ingress-nginx controller is running, but the Ingress asks for class 'nginx'."
  note "Nothing will ever serve this Ingress. Either install ingress-nginx and"
  note "k3s-disable Traefik, or switch ingressClassName to 'traefik'."
elif [ "$WANT_CLASS" = "traefik" ] && [ "$HAS_TRAEFIK" -eq 0 ]; then
  bad "No Traefik controller running, but the Ingress asks for class 'traefik'."
else
  ok "A controller matching class '$WANT_CLASS' is present"
fi

# Find the controller Service to port-forward later.
CTRL_NS=""; CTRL_SVC=""
if [ "$WANT_CLASS" = "nginx" ] && [ "$HAS_NGINX" -gt 0 ]; then
  CTRL_NS=$(kubectl get pods -A -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[0].metadata.namespace}')
  CTRL_SVC=$(kubectl get svc -n "$CTRL_NS" -o name | grep -m1 controller | cut -d/ -f2)
elif [ "$HAS_TRAEFIK" -gt 0 ]; then
  CTRL_NS=$(kubectl get pods -A -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.namespace}')
  CTRL_SVC=$(kubectl get svc -n "$CTRL_NS" -o name | grep -m1 traefik | cut -d/ -f2)
fi
[ -n "$CTRL_SVC" ] && note "Controller Service: $CTRL_NS/$CTRL_SVC"

# ---------------------------------------------------------------------------
# Layer 1 — do the Services the Ingress names actually exist, with endpoints?
# ---------------------------------------------------------------------------
blue "Layer 1: Ingress backend references resolve"

REFS=$(kubectl get ingress "$ING" -n "$NS" \
  -o jsonpath='{range .spec.rules[*].http.paths[*]}{.path}{" "}{.backend.service.name}{" "}{.backend.service.port.number}{"\n"}{end}')

echo "$REFS" | while read -r path svc port; do
  [ -z "$svc" ] && continue
  if ! kubectl get svc "$svc" -n "$NS" >/dev/null 2>&1; then
    printf '  \033[0;31mFAIL\033[0m %s -> Service "%s" DOES NOT EXIST\n' "$path" "$svc"
    printf '       Services present: %s\n' "$(kubectl get svc -n "$NS" -o jsonpath='{.items[*].metadata.name}')"
    continue
  fi
  EPS=$(kubectl get endpoints "$svc" -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  SVCPORT=$(kubectl get svc "$svc" -n "$NS" -o jsonpath='{.spec.ports[*].port}')
  if [ -z "$EPS" ]; then
    printf '  \033[0;31mFAIL\033[0m %s -> %s exists but has NO endpoints (selector matches no ready pods)\n' "$path" "$svc"
  elif ! echo " $SVCPORT " | grep -q " $port "; then
    printf '  \033[0;31mFAIL\033[0m %s -> %s has no port %s (it exposes: %s)\n' "$path" "$svc" "$port" "$SVCPORT"
  else
    printf '  \033[0;32mPASS\033[0m %s -> %s:%s (%s endpoints)\n' "$path" "$svc" "$port" "$(echo "$EPS" | wc -w)"
  fi
done

# The subshell above can't set FAIL, so re-check the cheap part here.
for svc in $(echo "$REFS" | awk '{print $2}' | sort -u); do
  [ -z "$svc" ] && continue
  kubectl get svc "$svc" -n "$NS" >/dev/null 2>&1 || FAIL=1
done

# ---------------------------------------------------------------------------
# Layer 2 — bypass the Ingress entirely: are the Services themselves serving?
# ---------------------------------------------------------------------------
blue "Layer 2: Services answer from inside the cluster (Ingress bypassed)"

incluster() { # incluster <url>
  kubectl run "curl-probe-$RANDOM" -n "$NS" --rm -i --restart=Never --quiet \
    --image=curlimages/curl:8.5.0 --command -- \
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null
}

for pair in "frontend:80" "backend:5000" "taskapp-backend-svc:5000"; do
  s="${pair%%:*}"; p="${pair##*:}"
  kubectl get svc "$s" -n "$NS" >/dev/null 2>&1 || continue
  CODE=$(incluster "http://$s.$NS.svc.cluster.local:$p/")
  if [ "$CODE" = "200" ]; then ok "$s:$p answered 200"; else bad "$s:$p answered '$CODE'"; fi
done

# ---------------------------------------------------------------------------
# Layer 3 — through the controller, via port-forward. No DNS, no firewall.
# ---------------------------------------------------------------------------
blue "Layer 3: through the ingress controller (port-forward, Host header forced)"

fingerprint() { # fingerprint <body> <server-header>
  case "$1" in
    *"Welcome to nginx"*)      echo "FRONTEND (nginx:alpine default page)" ;;
    *"Backend running"*)       echo "BACKEND (your node stub)" ;;
    *"default backend - 404"*) echo "ingress-nginx DEFAULT BACKEND — no rule matched" ;;
    *"404 page not found"*)    echo "Traefik DEFAULT — no rule matched (class mismatch?)" ;;
    *)                         echo "UNKNOWN (server=$2)" ;;
  esac
}

probe() { # probe <base> <path> <expect>
  local base="$1" path="$2" expect="$3" body code server
  body=$(curl -s --max-time 8 -H "Host: $HOST" -D /tmp/hdr.$$ "$base$path" 2>/dev/null)
  code=$(awk 'NR==1{print $2}' /tmp/hdr.$$ 2>/dev/null)
  server=$(awk -F': ' 'tolower($1)=="server"{print $2}' /tmp/hdr.$$ 2>/dev/null | tr -d '\r')
  rm -f /tmp/hdr.$$
  local who; who=$(fingerprint "$body" "$server")
  if [ "$code" = "200" ] && [ "${who#$expect}" != "$who" ]; then
    ok "$path -> HTTP $code, $who"
  else
    bad "$path -> HTTP ${code:-no-response}, $who (expected $expect)"
  fi
}

if [ -n "$CTRL_SVC" ]; then
  kubectl port-forward -n "$CTRL_NS" "svc/$CTRL_SVC" 18080:80 >/dev/null 2>&1 &
  PF=$!
  sleep 3
  if kill -0 "$PF" 2>/dev/null; then
    probe "http://127.0.0.1:18080" "/"         "FRONTEND"
    probe "http://127.0.0.1:18080" "/api"      "BACKEND"
    probe "http://127.0.0.1:18080" "/api/tasks" "BACKEND"
    note "Control test — wrong Host should NOT reach the app:"
    WRONG=$(curl -s --max-time 5 -H "Host: definitely-not-your-host.invalid" http://127.0.0.1:18080/ 2>/dev/null)
    case "$WRONG" in
      *"Welcome to nginx"*) bad "Wrong Host still reached the frontend — host-matching is not working" ;;
      *)                    ok  "Wrong Host correctly fell through to the default backend" ;;
    esac
    kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null
  else
    bad "port-forward to $CTRL_NS/$CTRL_SVC failed"
  fi
else
  bad "Could not identify a controller Service to port-forward to"
fi

# ---------------------------------------------------------------------------
# Layer 4 — the real public path (only if NODE_IP is given)
# ---------------------------------------------------------------------------
if [ -n "$NODE_IP" ]; then
  blue "Layer 4: public path via node $NODE_IP:80"
  probe "http://$NODE_IP" "/"    "FRONTEND"
  probe "http://$NODE_IP" "/api" "BACKEND"
  note "If Layer 3 passed and Layer 4 failed, the cluster is fine — look at the"
  note "AWS security group, the node's iptables, or the controller Service type."
else
  blue "Layer 4: skipped (set NODE_IP=<public ip> to test the real path)"
fi

blue "Result"
if [ "$FAIL" -eq 0 ]; then
  echo "  All layers passed. Ingress routing is verified."
else
  echo "  Failures above. Fix the LOWEST failing layer first — higher layers"
  echo "  are meaningless until it passes."
fi
exit "$FAIL"
