#!/bin/bash
# Run ONLY on the control plane node, after kubeadm init.
#
# We deliberately don't ship a static kube-flannel.yaml here. A
# hand-copied manifest previously included a PodSecurityPolicy object
# (policy/v1beta1) — that API was removed in Kubernetes 1.25+, so
# `kubectl apply` would fail on any current cluster. Flannel's own
# guidance is to apply the manifest attached to the latest release
# rather than a copy pinned elsewhere, since a stale copy can drift out
# of sync with the container image tags it references.
set -euo pipefail

kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "Waiting for flannel pods to become ready..."
kubectl -n kube-flannel rollout status ds/kube-flannel-ds --timeout=180s || \
  kubectl -n kube-system rollout status ds/kube-flannel-ds --timeout=180s
