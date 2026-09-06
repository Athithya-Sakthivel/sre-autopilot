#!/usr/bin/env bash
set -euo pipefail

for entry in "cloudflared:cloudflared-token" "task-api:backend-secrets" "task-api:frontend-secrets"; do
  ns="${entry%%:*}"
  name="${entry##*:}"

  kubectl delete secret "$name" -n "$ns" --ignore-not-found=true
  kubectl annotate externalsecret "$name" -n "$ns" \
    force-sync="$(date +%s)" --overwrite
done

sleep 5
kubectl get secret cloudflared-token -n cloudflared
kubectl get secret backend-secrets -n task-api
kubectl get secret frontend-secrets -n task-api
