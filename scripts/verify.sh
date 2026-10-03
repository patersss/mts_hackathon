#!/usr/bin/env bash
set -uo pipefail

failed=0
check() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "OK   ${name}"; else echo "FAIL ${name}"; failed=1; fi
}

pods_running() {
  kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"{bad=1} END{exit bad}'
}

check "node Ready" kubectl wait node --all --for=condition=Ready --timeout=120s
check "pods Running" pods_running

exit "${failed}"
