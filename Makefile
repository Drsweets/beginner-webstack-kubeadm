.PHONY: all deploy clean prereq-workers prereq-cp status zip help full-reset

METALLB_VERSION := v0.14.9
METALLB_URL := https://raw.githubusercontent.com/metallb/metallb/$(METALLB_VERSION)/config/manifests/metallb-native.yaml

help:
	@echo "Targets:"
	@echo "  prereq-workers  : OS/containerd/kubeadm/kubelet/kubectl setup (run on ALL 3 nodes)"
	@echo "  prereq-cp       : kubeadm init + Flannel + Traefik + local-path storage + MetalLB (control plane only)"
	@echo "  deploy          : apply webstack manifests"
	@echo "  clean           : delete webstack application resources"
	@echo "  full-reset      : delete webstack + metallb/traefik/flannel/local-path-provisioner"
	@echo "  status          : show nodes,pods,svc,ingress"
	@echo "  zip             : build zip archive of this project"

prereq-workers:
	bash prerequisites/00-containerd-setup.sh

prereq-cp:
	bash prerequisites/01-kubeadm-init.sh
	bash prerequisites/02-flannel-cni.sh
	kubectl apply -f prerequisites/03-traefik.yaml
	bash prerequisites/05-local-path-provisioner.sh
	kubectl apply -f $(METALLB_URL)
	kubectl -n metallb-system rollout status deploy/controller --timeout=120s
	kubectl apply -f prerequisites/04-metallb.yaml

deploy:
	bash deploy.sh

clean:
	kubectl delete -f 10-ingress.yaml --ignore-not-found
	kubectl delete -f 09-nginx-svc.yaml --ignore-not-found
	kubectl delete -f 08-nginx-deploy.yaml --ignore-not-found
	kubectl delete -f 07-php-svc.yaml --ignore-not-found
	kubectl delete -f 06-php-deploy.yaml --ignore-not-found
	kubectl delete -f 05-mariadb-svc.yaml --ignore-not-found
	kubectl delete -f 04-mariadb-deploy.yaml --ignore-not-found
	kubectl delete -f 03-mariadb-pvc.yaml --ignore-not-found
	kubectl delete -f 02-mariadb-secret.yaml --ignore-not-found
	kubectl delete -f 01-namespace.yaml --ignore-not-found

full-reset: clean
	kubectl delete -f prerequisites/04-metallb.yaml --ignore-not-found
	kubectl delete -f $(METALLB_URL) --ignore-not-found
	kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml --ignore-not-found
	kubectl delete -f prerequisites/03-traefik.yaml --ignore-not-found
	kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml --ignore-not-found

status:
	@echo "=== Nodes ==="
	kubectl get nodes -o wide
	@echo "\n=== webstack Pods ==="
	kubectl get pods -n webstack -o wide
	@echo "\n=== webstack Services ==="
	kubectl get svc -n webstack
	@echo "\n=== webstack Ingress ==="
	kubectl get ingress -n webstack

zip:
	zip -r k3d-beginner-webstack-kubeadm.zip . -x "*.zip"
	@echo "Created: k3d-beginner-webstack-kubeadm.zip"
