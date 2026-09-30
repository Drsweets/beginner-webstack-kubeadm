#!/bin/bash
set -euo pipefail
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-mariadb-secret.yaml
kubectl apply -f 03-mariadb-pvc.yaml
kubectl apply -f 04-mariadb-deploy.yaml
kubectl apply -f 05-mariadb-svc.yaml
kubectl apply -f 06-php-deploy.yaml
kubectl apply -f 07-php-svc.yaml
kubectl apply -f 08-nginx-deploy.yaml
kubectl apply -f 09-nginx-svc.yaml
kubectl apply -f 10-ingress.yaml
echo "Webstack deployed. Run 'make status' to verify."
