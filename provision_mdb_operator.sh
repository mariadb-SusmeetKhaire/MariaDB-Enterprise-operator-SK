#!/usr/bin/env bash
set -euo pipefail

GREEN="\e[32m"
RED="\e[31m"
NC="\e[0m"

echo -e "${GREEN}Provisioning MariaDB Enterprise Operator on RHEL8...${NC}"

###############################################
# 1. Install Docker (RHEL8)
###############################################
echo -e "${GREEN}Installing Docker...${NC}"

sudo dnf install -y yum-utils device-mapper-persistent-data lvm2
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io

sudo systemctl enable --now docker

# Add current user to docker group
sudo usermod -aG docker "$USER"

echo -e "${GREEN}Docker installed. If this is your first time, log out and log back in.${NC}"

###############################################
# 2. Reload docker group membership
###############################################
newgrp docker <<EOF
echo "Docker group activated."
EOF

###############################################
# 3. Install kubectl (official binary)
###############################################
echo -e "${GREEN}Installing kubectl...${NC}"

curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

###############################################
# 4. Install minikube (official binary)
###############################################
echo -e "${GREEN}Installing minikube...${NC}"

curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm -f minikube-linux-amd64

###############################################
# 5. Start minikube (Docker driver)
###############################################
echo -e "${GREEN}Starting minikube...${NC}"

minikube start --driver=docker --memory=2048mb --cpus=2

###############################################
# 6. Install Helm
###############################################
echo -e "${GREEN}Installing Helm...${NC}"

HELM_VERSION=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
curl -sL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o helm.tar.gz
tar -xzf helm.tar.gz
sudo mv linux-amd64/helm /usr/local/bin/helm
sudo chmod +x /usr/local/bin/helm
rm -rf linux-amd64 helm.tar.gz

###############################################
# 7. Prompt for MariaDB Enterprise credentials
###############################################
echo -e "${GREEN}Enter your MariaDB Enterprise Registry Username:${NC}"
read MDB_USER

echo -e "${GREEN}Enter your MariaDB Enterprise Registry Password (hidden):${NC}"
read -s MDB_PASS

if [[ -z "$MDB_USER" || -z "$MDB_PASS" ]]; then
    echo -e "${RED}Username and password cannot be empty.${NC}"
    exit 1
fi

###############################################
# 8. Create namespace
###############################################
echo -e "${GREEN}Creating namespace mariadb-operator...${NC}"

kubectl delete namespace mariadb-operator --ignore-not-found=true
kubectl create namespace mariadb-operator

###############################################
# 9. Create imagePullSecret
###############################################
echo -e "${GREEN}Creating imagePullSecret...${NC}"

kubectl create secret docker-registry mariadb-enterprise \
    --namespace mariadb-operator \
    --docker-server=docker.mariadb.com \
    --docker-username="$MDB_USER" \
    --docker-password="$MDB_PASS"

###############################################
# 10. Create values.yaml
###############################################
echo -e "${GREEN}Generating values.yaml...${NC}"

cat <<EOF > values.yaml
imagePullSecrets:
  - name: mariadb-enterprise

webhook:
  imagePullSecrets:
    - name: mariadb-enterprise

certController:
  imagePullSecrets:
    - name: mariadb-enterprise
EOF

###############################################
# 11. Add Helm repo
###############################################
echo -e "${GREEN}Adding MariaDB Operator Helm repo...${NC}"

helm repo add mariadb-enterprise-operator https://operator.mariadb.com || true
helm repo update

###############################################
# 12. Install CRDs
###############################################
echo -e "${GREEN}Installing CRDs...${NC}"

helm upgrade --install mariadb-enterprise-operator-crds \
    mariadb-enterprise-operator/mariadb-enterprise-operator-crds \
    --namespace mariadb-operator

###############################################
# 13. Install Operator
###############################################
echo -e "${GREEN}Installing MariaDB Enterprise Operator...${NC}"

helm upgrade --install mariadb-enterprise-operator \
    mariadb-enterprise-operator/mariadb-enterprise-operator \
    --namespace mariadb-operator \
    -f values.yaml

###############################################
# 14. Wait for rollout
###############################################
echo -e "${GREEN}Waiting for operator pods to become ready...${NC}"

kubectl rollout status deployment/mariadb-enterprise-operator -n mariadb-operator
kubectl rollout status deployment/mariadb-enterprise-operator-webhook -n mariadb-operator
kubectl rollout status deployment/mariadb-enterprise-operator-cert-controller -n mariadb-operator

echo -e "${GREEN}MariaDB Enterprise Operator successfully deployed!${NC}"

###############################################
# 15. Ask user if they want to deploy a topology
###############################################
echo -e "${GREEN}Would you like to deploy a MariaDB topology? (Y/N)${NC}"
read DEPLOY_TOPOLOGY

if [[ "$DEPLOY_TOPOLOGY" != "Y" && "$DEPLOY_TOPOLOGY" != "y" ]]; then
    echo -e "${GREEN}No topology selected. Exiting.${NC}"
    exit 0
fi

###############################################
# 16. Topology menu
###############################################
echo -e "${GREEN}Select topology:${NC}"
echo "1) Standalone"
echo "2) Highly Available"
read TOPOLOGY_CHOICE

###############################################
# 17. Standalone deployment
###############################################
if [[ "$TOPOLOGY_CHOICE" == "1" ]]; then
    echo -e "${GREEN}Enter root user password for standalone MariaDB:${NC}"
    read -s ROOT_PASS

    # Create secret.yaml
    cat <<EOF > secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: mariadb
stringData:
  password: $ROOT_PASS
EOF

    kubectl apply -f secret.yaml -n mariadb-operator

    # Create mariadb.yaml
    cat <<EOF > mariadb.yaml
apiVersion: enterprise.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb
spec:
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password

  image: docker.mariadb.com/enterprise-server:latest
  imagePullPolicy: Always
  imagePullSecrets:
  -  name: mariadb-enterprise

  replicas: 1

  storage:
    size: 1Gi

EOF

    kubectl apply -f mariadb.yaml -n mariadb-operator

    echo -e "${GREEN}Waiting for standalone MariaDB pods to appear...${NC}"
    sleep 5
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb -n mariadb-operator --timeout=300s

    echo -e "${GREEN}Standalone MariaDB deployed.${NC}"
fi

###############################################
# 18. Highly Available deployment
###############################################
if [[ "$TOPOLOGY_CHOICE" == "2" ]]; then
    echo -e "${GREEN}Choose HA mode:${NC}"
    echo "1) Galera"
    echo "2) Replication"
    read HA_MODE

    echo -e "${GREEN}How many nodes/replicas?${NC}"
    read REPLICAS

    echo -e "${GREEN}Enter root user password for HA cluster:${NC}"
    read -s ROOT_PASS

    # Create secret.yaml
    cat <<EOF > secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: mariadb
stringData:
  password: $ROOT_PASS
EOF

    kubectl apply -f secret.yaml -n mariadb-operator

    ###############################################
    # Galera cluster
    ###############################################
    if [[ "$HA_MODE" == "1" ]]; then
        cat <<EOF > mariadb-cluster.yaml
apiVersion: enterprise.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb-galera
spec:
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password
  image: docker.mariadb.com/enterprise-server:latest
  imagePullPolicy: Always
  imagePullSecrets:
  -  name: mariadb-enterprise
  replicas: $REPLICAS
  galera:
    enabled: true
  storage:
    size: 1Gi
EOF

        kubectl apply -f mariadb-cluster.yaml -n mariadb-operator

        echo -e "${GREEN}Waiting for Galera cluster pods to appear...${NC}"
        sleep 5
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb -n mariadb-operator --timeout=300s

        echo -e "${GREEN}Galera cluster deployed.${NC}"
    fi

    ###############################################
    # Replication cluster
    ###############################################
    if [[ "$HA_MODE" == "2" ]]; then
        cat <<EOF > mariadb-cluster.yaml
apiVersion: enterprise.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb-repl
spec:
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password
  image: docker.mariadb.com/enterprise-server:latest
  imagePullPolicy: Always
  imagePullSecrets:
  -  name: mariadb-enterprise
  replicas: $REPLICAS
  replication:
    enabled: true
  storage:
    size: 1Gi
EOF

        kubectl apply -f mariadb-cluster.yaml -n mariadb-operator

        echo -e "${GREEN}Waiting for Replication cluster pods to appear...${NC}"
        sleep 5
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb -n mariadb-operator --timeout=300s

        echo -e "${GREEN}Replication cluster deployed.${NC}"
    fi
fi

###############################################
# 19. Show final pod status
###############################################
echo -e "${GREEN}Deployment complete. Current pod status:${NC}"
kubectl get pods -o wide -n mariadb-operator

echo -e "${GREEN}All tasks completed. Exiting.${NC}"
exit 0
