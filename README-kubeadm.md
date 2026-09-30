# k3d-beginner-webstack — Kubeadm Edition

A beginner-friendly LEMP stack (Nginx + PHP-FPM + MariaDB) on a **vanilla kubeadm**
cluster, fronted by Traefik as the Ingress controller.

Original repo (k3d/k3s version): https://github.com/Drsweets/k3d-beginner-webstack.git
This version replaces the k3d/k3s bootstrap with kubeadm equivalents and adds the
one thing vanilla kubeadm lacks out of the box: a default StorageClass (see
"What was fixed" at the bottom).

---

## 1. Architecture & topology

```
                 ┌────────────────────────────────────────────┐
   curl -H Host  │  any node IP :80 (Traefik DaemonSet hostPort)
                 ▼
        ┌─────────────────┐         ┌───────────────┐
        │  Traefik (DS)   │────────▶│ nginx:80      │──┐
        │  IngressClass   │  Ingress│ (fastcgi_pass)│  │
        └─────────────────┘         └──────┬────────┘  │
                                           │ php:9000  │
                                           ▼           │
                                     ┌───────────┐     │
                                     │ php-fpm   │     │
                                     └───────────┘     │
                                           │ SQL        │
                                           ▼            │
                                     ┌───────────┐      │
                                     │ MariaDB   │◀─────┘
                                     │ PVC: local-path
                                     └───────────┘
```

- **Nodes:** 1 control plane + 2 workers (tested on Ubuntu VMs; Proxmox works fine).
  A single-node cluster also works — just skip the worker join steps.
- **Namespace:** `webstack`
- **Ingress host:** `webstack.homelab.local` (resolve it to any node IP, e.g. via `/etc/hosts`).

## 2. File map

| File | What it does | Where it runs |
|---|---|---|
| `prerequisites/00-containerd-setup.sh` | OS prep + containerd + kubelet/kubeadm/kubectl | **ALL nodes** |
| `prerequisites/01-kubeadm-init.sh` | `kubeadm init` + kubeconfig setup | control plane only |
| `prerequisites/02-flannel-cni.sh` | Flannel CNI (live upstream manifest) | control plane only |
| `prerequisites/03-traefik.yaml` | Traefik DaemonSet + RBAC + IngressClass | control plane only |
| `prerequisites/04-metallb.yaml` | MetalLB IPAddressPool/L2Advertisement (optional) | control plane only |
| `prerequisites/05-local-path-provisioner.sh` | Default StorageClass for the MariaDB PVC | control plane only |
| `01-namespace.yaml` … `10-ingress.yaml` | The LEMP app itself | control plane only |
| `deploy.sh` / `Makefile` | Apply/remove everything in the right order | control plane only |

## 3. Step-by-step execution

### Phase 0 — Prepare every node (control plane AND all workers)

```bash
# Run on ALL nodes, as a user with sudo:
make prereq-workers
```

This one target runs `prerequisites/00-containerd-setup.sh`, which:
1. Disables swap (`swapoff -a` + comments it out of `/etc/fstab`) — kubelet refuses to run with swap on.
2. Loads `overlay` and `br_netfilter` kernel modules and persists them via `/etc/modules-load.d/k8s.conf`.
3. Sets `bridge-nf-call-iptables`, `bridge-nf-call-ip6tables` and `ip_forward` sysctls.
4. Installs containerd from Ubuntu's repo and rewrites `/etc/containerd/config.toml`
   with **`SystemdCgroup = true`** — without this, containerd (cgroupfs) and kubelet
   (systemd) disagree and kubelet crash-loops after init/join.
5. Adds the official `pkgs.k8s.io` apt repo (pinned to Kubernetes **v1.33** — see the note in `00-containerd-setup.sh` about picking a currently supported release) and installs
   `kubelet`, `kubeadm`, `kubectl` (held at that version).

**Verify per node:**
```bash
sudo systemctl is-active containerd kubelet   # containerd: active, kubelet: activating/crashloop UNTIL init is OK — see Phase 1
kubeadm version && kubectl version --client
```

> **Note:** kubelet reporting `activating` or even crash-looping with
> `connection refused` to the API server **before** `kubeadm init`/`join` is normal.

### Phase 1 — Initialize the control plane

```bash
# Control plane only:
make prereq-cp        # runs 01-kubeadm-init.sh first, then the rest
```

`prerequisites/01-kubeadm-init.sh` runs:
```bash
sudo kubeadm init --pod-network-cidr=10.244.0.0/16   # matches Flannel's default range
```
then copies `/etc/kubernetes/admin.conf` to `~/.kube/config`.

**Verify:**
```bash
kubectl get nodes
# NAME     STATUS     ROLES           AGE   VERSION
# cp-1     NotReady   control-plane   1m    v1.31.x     <-- NotReady is EXPECTED (no CNI yet)
```

> ⚠️ **Save the `kubeadm join ...` command** printed at the end of `kubeadm init`.
> You'll need it for each worker in Phase 2. Lost it? Regenerate:
> ```bash
> kubeadm token create --print-join-command
> ```

The rest of `make prereq-cp` then runs automatically, **in this order**:

| Step | Command | What lands in the cluster |
|---|---|---|
| 1 | `02-flannel-cni.sh` | Flannel DaemonSet (`kube-flannel` ns) — the CNI |
| 2 | `kubectl apply -f prerequisites/03-traefik.yaml` | Traefik DaemonSet (`kube-system`), RBAC, default IngressClass `traefik` |
| 3 | `05-local-path-provisioner.sh` | Rancher local-path-provisioner + StorageClass `local-path` (marked **default**) |
| 4 | MetalLB native manifest + `04-metallb.yaml` | LoadBalancer IP pool `192.168.1.200-192.168.1.210` (see note below) |

> **MetalLB is optional for this stack.** Traefik is exposed via `hostPort` 80/443 on
> every node, so Ingress already works without a LoadBalancer IP. If you skip MetalLB,
> delete the last two lines of the `prereq-cp` target or just ignore the failing pool
> apply (the app doesn't use LoadBalancer Services). **If you keep it, edit
> `prerequisites/04-metallb.yaml` and change the address range to match YOUR LAN** —
> the shipped `192.168.1.200-210` range is a placeholder.

**Verify after `make prereq-cp` finishes:**
```bash
kubectl get nodes                                   # cp-1 should be Ready now
kubectl -n kube-flannel get pods                    # flannel pod Running
kubectl -n kube-system get pods -l app=traefik      # traefik pod Running on cp-1
kubectl -n local-path-storage get pods              # local-path-provisioner Running
kubectl get storageclass                            # local-path (default)   <-- critical
kubectl get ingressclass                            # traefik (default)
```

### Phase 2 — Join the workers

On **each worker node**, run the join command from Phase 1, e.g.:

```bash
sudo kubeadm join <CP-IP>:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

**Verify from the control plane:**
```bash
kubectl get nodes -o wide
# cp-1    Ready   control-plane   ...
# wrk-1   Ready   <none>          ...
# wrk-2   Ready   <none>          ...
kubectl get pods -A -o wide | grep -v Running
# (only Completed/blank output expected once images finish pulling)
```

### Phase 3 — Deploy the webstack

```bash
# Control plane:
make deploy
```

`deploy.sh` applies, in order:
1. `01-namespace.yaml` — namespace `webstack`
2. `02-mariadb-secret.yaml` — Secret `mariadb-creds` (user `admin`, db `webstack_db`, password `bGkXBj4Gxl4iDpTnNBgV` — rotate it in `02-mariadb-secret.yaml` **before the first deploy**)
3. `03-mariadb-pvc.yaml` — PVC `mariadb-pvc` (5Gi, `storageClassName: local-path`)
4. `04-mariadb-deploy.yaml` + `05-mariadb-svc.yaml` — MariaDB 10.11 + ClusterIP service
5. `06-php-deploy.yaml` + `07-php-svc.yaml` — PHP-FPM + ClusterIP service
6. `08-nginx-deploy.yaml` + `09-nginx-svc.yaml` — Nginx (config via ConfigMap, proxies PHP to `php:9000`) + ClusterIP service
7. `10-ingress.yaml` — Ingress `webstack.homelab.local` → nginx:80

**Verify:**
```bash
make status
# Expect: 3/3 nodes Ready; pods mariadb-*, php-*, nginx-* Running in webstack;
# three ClusterIP services; one ingress.
```

### Phase 4 — Test

```bash
# Add the ingress host to /etc/hosts on the machine you'll test FROM:
echo "<ANY-NODE-IP> webstack.homelab.local" | sudo tee -a /etc/hosts

curl -H "Host: webstack.homelab.local" http://<ANY-NODE-IP>/
```

**Expected result: an HTTP 404 from Nginx — that means the whole chain works.**
There is deliberately no application code shipped (see "Known limitations"), so
Nginx has no `index.php` to serve. If you get a 404 with an Nginx error page, the
stack is up end-to-end (client → Traefik → Ingress → Nginx → PHP upstream).

Sanity-check PHP-FPM connectivity explicitly if you like:
```bash
kubectl -n webstack exec deploy/php -- sh -c 'echo "<?php phpinfo(); ?>" > /var/www/html/info.php'
curl -H "Host: webstack.homelab.local" http://<ANY-NODE-IP>/info.php
# ^^ still 404 for now — see the shared-volume limitation below; the Nginx pod can't see the PHP pod's emptyDir
```

## 4. Troubleshooting pointers

**`make prereq-workers` / `kubeadm init` fails with a cgroup or preflight error**
- `systemctl status containerd` → if containerd is running with the wrong driver,
  re-check `/etc/containerd/config.toml` contains `SystemdCgroup = true` and restart containerd.
- `swapon --show` must output **nothing**. If swap crept back, `sudo swapoff -a` and re-check `/etc/fstab`.
- `lsmod | grep -E 'overlay|br_netfilter'` — both must be listed.

**`kubeadm join` on a worker fails**
- Wrong token/hash → regenerate on the CP: `kubeadm token create --print-join-command`.
- `connection refused` to port 6443 → CP firewall/security group must allow **6443/tcp**
  inbound on the control plane (and **80/443** for the Ingress test).
- Time skew breaks TLS — sync clocks (`chronyc makestep` or `sudo timedatectl set-ntp true`).

**Node stays `NotReady` after join**
- `kubectl describe node <node>` — a `container runtime is down` or `network plugin not ready` message means Phase 1/2 pieces didn't land.
- `kubectl -n kube-flannel get pods -o wide` — flannel must be Running **on every node**. If a worker's flannel pod is missing, re-apply: `kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml`.

**`mariadb` pod stuck `Pending`**
- `kubectl -n webstack describe pvc mariadb-pvc` — if the Events say
  `waiting for a volume to be created`, the StorageClass step of Phase 1 was skipped or failed:
  ```bash
  kubectl get storageclass                    # must show local-path (default)
  bash prerequisites/05-local-path-provisioner.sh
  ```
- Also check node disk space — local-path provisions on the node's own disk.

**MariaDB pod `CrashLoopBackOff`**
- `kubectl -n webstack logs deploy/mariadb` — most common cause: the PVC already contains
  data initialized with a *different* root password (local-path reuses the host directory).
  Fix: `kubectl -n webstack delete pvc mariadb-pvc` (deletes data!) then `kubectl apply -f 03-mariadb-pvc.yaml`,
  or keep passwords stable.

**`curl` returns `connection refused` on port 80**
- Traefik isn't listening on that node: `kubectl -n kube-system get pods -o wide -l app=traefik`.
  As a DaemonSet there should be one pod **per node** — if a node has none, check
  `kubectl describe node <node> | grep -A5 Taints` and node conditions.
- Something else on the host already bound port 80 (common on dev boxes): `sudo ss -tlnp | grep ':80 '`.

**`curl` returns `404 page not found` (plain text, from Traefik) instead of an Nginx-styled 404**
- That's Traefik saying "no route matched" — the Host header doesn't match `webstack.homelab.local`
  exactly, or the Ingress isn't picked up: `kubectl -n webstack describe ingress webstack-ingress`
  must show an `IngressClass` of `traefik` and an address. `kubectl get ingressclass` must list `traefik` (default).

**Images won't pull on workers (`ImagePullBackOff`)**
- Every node needs outbound internet access to `docker.io` (mariadb, php, nginx, traefik)
  and `registry.k8s.io`/`ghcr.io` (flannel, local-path, metallb). Air-gapped labs must
  mirror images or preload them (`ctr -n k8s.io images import ...`).

**MetalLB-speaker won't start / pool never advertises**
- Only relevant if you enabled MetalLB. Ensure the IP range in `04-metallb.yaml` is on the
  same L2 segment as your nodes and doesn't collide with your DHCP pool. The stack does
  **not** need MetalLB to work — the hostPort Traefik is the real entry point.

**Reset and retry**
```bash
make clean         # deletes only the webstack app resources
make full-reset    # also removes MetalLB/Traefik/Flannel/local-path-provisioner
sudo kubeadm reset -f   # on a node, to wipe kubeadm state (then rerun Phase 0/1/2)
```

**Where to look, in general (on the control plane):**
```bash
make status                                        # one-shot overview
kubectl get events -n webstack --sort-by=.lastTimestamp
kubectl -n webstack logs deploy/<name> --previous  # if it crash-looped
journalctl -u kubelet -f                           # node-level kubelet errors
```

## 5. Known limitations (carried over from the original app, not kubeadm-specific)

1. **Nginx and PHP-FPM don't share a filesystem.** Each Deployment mounts its own
   `emptyDir` volume named `webroot`. Code written into the PHP pod's webroot is
   invisible to Nginx (hence the expected 404 in the test). To serve real code, give
   both pods a shared volume (e.g. a `ReadWriteMany` PVC, or an initContainer that
   syncs code into a shared PVC) — that would be an app-manifest change and is
   intentionally **not** done here per the "leave the app manifests unchanged" instruction.
2. **Root and app passwords are identical** — `MYSQL_ROOT_PASSWORD` and `MYSQL_PASSWORD`
   both read the `dbpass` key of `mariadb-creds`. Functional, but unusual practice.
3. **Single replica of everything** — MariaDB is one Pod with local storage; node
   failure = database downtime. Fine for a homelab/beginner stack.
4. **Secret values are base64, not encrypted** — `admin` / `bGkXBj4Gxl4iDpTnNBgV` (generated for this bundle). Do not reuse
   these credentials anywhere real.

## 6. What was fixed vs. the k3d original (for reference)

1. Dead apt repo (`apt.kubernetes.io`) → official `pkgs.k8s.io`, pinned to v1.33 (v1.31 and older are end-of-life).
2. Swap not disabled → `swapoff -a` + fstab handling in `00-containerd-setup.sh`.
3. containerd `cgroupfs` vs kubelet `systemd` mismatch → generated config with `SystemdCgroup = true`.
4. Flannel manifest contained a `PodSecurityPolicy` (API removed in K8s 1.25+) → apply the live release manifest instead.
5. No default StorageClass on kubeadm (PVC would sit `Pending` forever) → added `local-path-provisioner`
   as a prerequisite and set `storageClassName: local-path` on the PVC.
6. Traefik: removed unused `IngressRoute` CRD; added an explicit default `IngressClass`
   and referenced it from the Ingress.
7. Makefile had MetalLB URLs pasted in Markdown link syntax (`[text](url)`) → fixed to plain URLs.

## 7. Cleanup

```bash
make clean         # webstack app resources only (safe to re-run make deploy after)
make full-reset    # everything above + metallb/traefik/flannel/local-path-provisioner
```

To fully decommission a node: `sudo kubeadm reset -f` (plus `sudo rm -rf /etc/cni/net.d` if CNI leftovers linger).
