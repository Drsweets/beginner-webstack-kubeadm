#!/bin/bash
# Run ONLY on the control plane node
set -euo pipefail

sudo kubeadm init --pod-network-cidr=10.244.0.0/16

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo
echo "=================================================================="
echo " Control plane is up. Copy the 'kubeadm join ...' command that"
echo " kubeadm printed above and run it (with sudo) on EACH worker node."
echo
echo " If you lose it, regenerate it from the control plane with:"
echo "   kubeadm token create --print-join-command"
echo "=================================================================="
