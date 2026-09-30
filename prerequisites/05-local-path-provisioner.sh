#!/bin/bash
# Run ONLY on the control plane node.
#
# k3s ships Rancher's local-path-provisioner by default, which is why a
# PVC with no storageClassName "just works" on k3d/k3s. Vanilla kubeadm
# has NO default StorageClass at all, so 03-mariadb-pvc.yaml would sit
# in `Pending` forever without this. local-path-provisioner is a plain
# Kubernetes Deployment + StorageClass — it isn't k3s-specific, k3s just
# bundles it — so it works fine here too. It backs PVCs with a hostPath
# directory on whichever node the Pod lands on, which is fine for a
# single-replica MariaDB in a homelab.
set -euo pipefail

LOCAL_PATH_VERSION="v0.0.37"

kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"

echo "Waiting for local-path-provisioner to become ready..."
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s

# Mark it default so any PVC without an explicit storageClassName also binds.
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
