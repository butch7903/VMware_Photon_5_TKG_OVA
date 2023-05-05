#!/bin/bash
# Setup Tdarr
echo '  Preparing for Tdarr ...'
# Reference: https://artifacthub.io/packages/helm/k8s-at-home/tdarr
# Reference: https://github.com/k8s-at-home/charts/tree/master/charts/stable/tdarr

# Add Function
lastreleaseversion() { git -c 'versionsort.suffix=-' ls-remote --tags --sort='v:refname' "$1" | cut -d/ -f3- | tail -n1 | cut -d '^' -f 1 | cut -d 'v' -f 2; }

# Versions
#Internal Domain name
DOMAIN_NAME=$(hostname -d)
#Internal DNS Entry to that resolves to the Tdarr fqdn - you must make this DNS Entry
TDARR_SQDN="tdarr"
TDARR_FQDN="${TDARR_SQDN}.${DOMAIN_NAME}"
#Tanzu/Kubernetes cluster name
CLUSTER_NAME='local-cluster'
#Control Plane Name
CONTROL_PLANE="$CLUSTER_NAME"-control-plane
#Location Name
USERD=root
# Github Variables for YAML files
#REPO="https://github.com/guarddog-dev"
#REPONAME="VMware_Photon_OVA"
#REPOFOLDER="yaml"

# Setup KinD
echo "   Creating KinD Kubernetes Cluster ..."

#Create Cluster yaml
# https://kind.sigs.k8s.io/docs/user/ingress
cat <<EOF > ./kind-calico.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: local-cluster
networking:
  # the default CNI will not be installed
  disableDefaultCNI: true # disable kindnet
  podSubnet: 192.168.0.0/16  # set to Calico's default subnet
  serviceSubnet: "10.96.0.0/12"
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
EOF

#Create Cluster
kind create cluster --config kind-calico.yaml

#Install the Tigera Calico operator
echo "   Deploying Calico Tigera operator on Cluster $CLUSTER_NAME ..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.2/manifests/tigera-operator.yaml

#Install Calico
echo "   Deploying Calico CNI on Cluster $CLUSTER_NAME ..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.2/manifests/custom-resources.yaml

#Deploy Carvel secretgen controller
echo "   Deploying Carvel secretgen controller on Cluster $CLUSTER_NAME ..."
kapp deploy -a sg -f https://github.com/vmware-tanzu/carvel-secretgen-controller/releases/latest/download/release.yml -y

#Deploy Carvel kapp controller
echo "   Deploying Carvel kapp controller on Cluster $CLUSTER_NAME ..."
kapp deploy -a kc -f https://github.com/vmware-tanzu/carvel-kapp-controller/releases/latest/download/release.yml -y

# Valideate Cluster is ready
echo "   Validating Cluster $CLUSTER_NAME is Ready ..."
STATUS=NotReady
while [[ $STATUS != "Ready" ]]
do
echo "   Kubernetes Cluster $CLUSTER_NAME Status - NotReady"
sleep 10s
STATUS=$(kubectl get nodes -n $CONTROL_PLANE | tail -n +2 | awk '{print $2}')
done
echo "   Kubernetes Cluster $CLUSTER_NAME Status - Ready"
kubectl get nodes,po -A
sleep 20s

## Install Tdarr
echo "   Adding helm repo K8s for tdarr deployment ..."
helm repo add k8s-at-home https://k8s-at-home.com/charts/
helm repo update

# Create Namespace tdarr
echo "   Creating Namespace tdarr ..."
kubectl create namespace tdarr

# Get Timezone from OVA
TZ=$(timedatectl status | grep "Time zone" | cut -d ":" -f 2 | cut -d " " -f 2)
echo "   Applying system timezone $TZ for tdarr ..."

# Install Tdarr
echo "   Using helm to install tdarr ..."
helm install tdarr k8s-at-home/tdarr \
  --namespace tdarr \
  --replace \
  --set hostNetwork="true" \
  --set env.TZ="${TZ}" \
  --set ingress.main.enabled="true" \
  --set persistence.config.enabled="true" \
  --set hostname="${TDARR_SQDN}" \
  --set subdomain="$(hostname -d)" \
  --set service.main.ports.http.port="80" \
  --set node.enabled="true"

# Validate that tdarr pod is ready
echo "   Validate that tdarr pod is ready ..."
TDARRPOD=$(kubectl get po -n tdarr | grep tdarr | cut -d " " -f 1)
while [[ $(kubectl get po -n tdarr $TDARRPOD -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "Waiting for pod $TDARRPOD to be ready" && sleep 10s; done
echo "   Pod $TDARRPOD is now ready ..."

# Show tdarr  pod info
echo "   tdarr pod info: ..."
kubectl get pods -n tdarr -o wide
kubectl get services -n tdarr -o wide
kubectl describe services -n tdarr
kubectl get ingress -n tdarr -A
#kubectl logs ${TDARRPOD} -n tdarr --all-containers

# Echo Completion
sleep 10s
IP_ADDRESS=$(/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
clear
echo "   Tdarr pod deployed ..."
echo "   You can access tdarr by going to:"
echo "                                      http://$TDARR_FQDN"
echo "                                      or"
echo "                                      http://$IP_ADDRESS"
echo " "
echo "   Note: You must make a DNS or HOST File entry for $TDARR_FQDN to be able to be accessed"
sleep 60s
