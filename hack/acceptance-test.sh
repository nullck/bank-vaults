#!/usr/bin/env bash
set -xeo pipefail

function waitfor {
    WAIT_MAX=0
    until $@ &> /dev/null || [ $WAIT_MAX -eq 45 ]; do
        sleep 1
        (( WAIT_MAX = WAIT_MAX + 1 ))
    done
}

function finish {
    echo "The last command was: $(history 1 | awk '{print $2}')"
    kubectl get pods
    kubectl describe pods
    kubectl logs deployment/vault-operator
    kubectl get services --show-labels -l vault_cr=vault
    kubectl get ep --show-labels -l vault_cr=vault
    kubectl logs deployment/vault-configurer
    kubectl logs -n vswh deployment/vault-secrets-webhook
    kubectl describe deployment/hello-secrets
    kubectl describe rs hello-secrets
    kubectl describe pod hello-secrets
    kubectl logs deployment/hello-secrets --all-containers
    kubectl get secret -n vswh -o yaml
}

function check_webhook_seccontext {
    kubectl describe deployment/hello-secrets-seccontext
    kubectl describe rs hello-secrets-seccontext
    kubectl describe pod hello-secrets-seccontext
    kubectl logs deployment/hello-secrets-seccontext --all-containers
}

trap finish EXIT

# Create a resource quota in the default namespace
kubectl create quota bank-vaults --hard=cpu=2,memory=4G,pods=10,services=10,replicationcontrollers=10,secrets=10,persistentvolumeclaims=10

# Install the operators and companion
kubectl apply -f operator/deploy/etcd-rbac.yaml
kubectl apply -f operator/deploy/etcd-operator.yaml
kubectl wait --for=condition=available deployment/etcd-operator --timeout=120s

kubectl apply -f operator/deploy/operator-rbac.yaml
kubectl apply -f operator/deploy/operator.yaml
kubectl wait --for=condition=available deployment/vault-operator --timeout=120s

# Install common RBAC setup for CRs
kubectl apply -f operator/deploy/rbac.yaml

# First test: HA setup with etcd
kubectl apply -f operator/deploy/cr-etcd-ha.yaml
waitfor kubectl get etcdclusters.etcd.database.coreos.com/etcd-cluster
kubectl wait --for=condition=available etcdclusters.etcd.database.coreos.com/etcd-cluster --timeout=120s
waitfor kubectl get pod/vault-0
waitfor kubectl get pod/vault-1
kubectl wait --for=condition=ready pod/vault-0 --timeout=120s
kubectl delete -f operator/deploy/cr-etcd-ha.yaml
kubectl wait --for=delete pod/vault-0 --timeout=120s || true
kubectl wait --for=delete pod/vault-1 --timeout=120s || true

# Second test: test the external secrets watcher work and match as expected
kubectl apply -f deploy/test-external-secrets-watch-deployment.yaml
waitfor kubectl get pod/vault-0
kubectl wait --for=condition=ready pod/vault-0 --timeout=120s
test x`kubectl get pod vault-0 -o jsonpath='{.metadata.annotations.vault\.banzaicloud\.io/watched-secrets-sum}'` = "x"
kubectl delete -f deploy/test-external-secrets-watch-deployment.yaml
kubectl wait --for=delete pod/vault-0 --timeout=120s || true

kubectl apply -f deploy/test-external-secrets-watch-secrets.yaml
kubectl apply -f deploy/test-external-secrets-watch-deployment.yaml
waitfor kubectl get pod/vault-0
kubectl wait --for=condition=ready pod/vault-0 --timeout=120s

test x`kubectl get pod vault-0 -o jsonpath='{.metadata.annotations.vault\.banzaicloud\.io/watched-secrets-sum}'` = "xbac8dfa8bdf03009f89303c8eb4a6c8f2fd80eb03fa658f53d6d65eec14666d4"
kubectl delete -f deploy/test-external-secrets-watch-deployment.yaml
kubectl delete -f deploy/test-external-secrets-watch-secrets.yaml
kubectl wait --for=delete pod/vault-0 --timeout=120s || true

# Third test: single node cluster with defined PriorityClass via vaultPodSpec and vaultConfigurerPodSpec
kubectl apply -f operator/deploy/priorityclass.yaml
kubectl apply -f operator/deploy/cr-priority.yaml
waitfor kubectl get pod/vault-0
kubectl wait --for=condition=ready pod/vault-0 --timeout=120s

# Run a client test

# Give bank-vaults some time to let the Kubernetes auth backend configuration happen
sleep 20

# Run an internal client which tries to read from Vault with the configured Kubernetes auth backend
kurun run cmd/examples/main.go


# Run the webhook test, the hello-secrets deployment should be successfully mutated
helm install ./charts/vault-secrets-webhook \
    --name vault-secrets-webhook \
    --set image.tag=latest \
    --set image.pullPolicy=IfNotPresent \
    --set configMapMutation=true \
    --set configmapFailurePolicy=Fail \
    --set podsFailurePolicy=Fail \
    --set secretsFailurePolicy=Fail \
    --set env.VAULT_ENV_IMAGE=banzaicloud/vault-env:latest \
    --namespace vswh \
    --wait

kubectl apply -f deploy/test-secret.yaml
test `kubectl get secrets sample-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode | jq -r '.auths[].username'` = "dockerrepouser"
test `kubectl get secrets sample-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 --decode | jq -r '.auths[].password'` = "dockerrepopassword"

kubectl apply -f deploy/test-configmap.yaml
test `kubectl get cm sample-configmap -o jsonpath='{.data.aws-access-key-id}'` = "secretId"
test `kubectl get cm sample-configmap -o jsonpath='{.binaryData.aws-access-key-id-binary}'` = "secretId"

kubectl apply -f deploy/test-deployment-seccontext.yaml
kubectl wait --for=condition=available deployment/hello-secrets-seccontext --timeout=120s
check_webhook_seccontext
kubectl delete -f deploy/test-deployment-seccontext.yaml

kubectl apply -f deploy/test-deployment.yaml
kubectl wait --for=condition=available deployment/hello-secrets --timeout=120s
