#!/usr/bin/env bash
# Simulates the RFC-0014 build pipeline: one Kustomize pass per consumed
# transformer set, instead of co-locating both packs in a single build.
# Both packs ship SecurityBaseline/restricted; co-location fails, passes do not.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

kustomize build "$here/app" > "$work/step0.yaml"

step=0
for pack in baseline-a baseline-b; do
  next=$((step + 1))
  mkdir -p "$work/pass$next"
  cp "$work/step$step.yaml" "$work/pass$next/in.yaml"
  cp "$here/components/$pack/baseline.yaml" "$work/pass$next/companion.yaml"
  cp "$here/components/$pack/replacement.yaml" "$work/pass$next/xf.yaml"
  cat > "$work/pass$next/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - in.yaml
  - companion.yaml
transformers:
  - xf.yaml
EOF
  kustomize build "$work/pass$next" > "$work/step$next.yaml"
  echo "pass $next ($pack): ok"
  step=$next
done

echo "--- final output ---"
cat "$work/step$step.yaml"
