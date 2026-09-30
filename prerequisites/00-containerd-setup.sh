#!/bin/bash
# Run on ALL nodes (control plane + both workers)
set -euo pipefail

KUBE_VERSION="v1.33"   # pick the minor version you want; must match on every node
                       # check https://kubernetes.io/releases/ for currently supported releases
                       # (v1.31 and older are end-of-life and receive no patches)

echo "==> Disabling swap"
sudo swapoff -a
sudo sed -i '/\sswap\s/ s/^/#/' /etc/fstab

echo "==> Loading required kernel modules"
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

echo "==> Setting required sysctls"
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "==> Installing containerd"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg containerd

echo "==> Configuring containerd to use the systemd cgroup driver"
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "==> Adding the Kubernetes apt repository (pkgs.k8s.io)"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "==> Installing kubelet, kubeadm, kubectl"
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "==> Done. kubeadm/kubelet/kubectl and containerd are installed and configured on this node."
