#!/bin/bash
# Setup Tailscale VPN
echo '   Creating Unmanaged Cluster with Tailscale VPN ...'
# Reference: https://tailscale.com/kb/1185/kubernetes/

#Request Tailscale Auth Key
echo " "
echo "   Please provide the Tailscale Auth Key ..."
echo "   Example: tskey-123456789ABCDEF"
read AUTH_KEY
echo "   Will use AUTH Key $AUTH_KEY ..."
echo " "

# Versions
# MetalLb Load Balancer Version
METALLBVERSION="0.12.1"
#Version of Local Path Storage to install
LOCAL_PATH_STORAGE_PACKAGE_VERSION="0.0.20"
#Tanzu/Kubernetes cluster name
CLUSTER_NAME='local-cluster'
#Control Plane Name
CONTROL_PLANE="$CLUSTER_NAME"-control-plane

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
  - containerPort: 1194
    hostPort: 1194
  - containerPort: 9443
    hostPort: 9443
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

# Clone Repo
echo "   Cloning Tailscale Repo ..."
git clone https://github.com/tailscale/tailscale.git
cd tailscale/docs/k8s

# Create secret with tailscale AUTH Key
echo "   Creating Auth key secret for tailscale ..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: tailscale-auth
stringData:
  AUTH_KEY: $AUTH_KEY
EOF

# Configure RBAC
echo "   Configuring RBAC for tailscale ..."
export SA_NAME=tailscale
export TS_KUBE_SECRET=tailscale-auth
make rbac

<<com
# Create Namespace
echo "   Creating Namespace tailscale ..."
kubectl create namespace tailscale

# Create Tailscale Nginx Proxy
echo "   Creating Tailscale Nginx Proxy ..."
kubectl create deployment nginx --image nginx --namespace tailscale
kubectl expose deployment nginx --port 80 --namespace tailscale
export TS_DEST_IP="$(kubectl get svc nginx --namespace tailscale -o=jsonpath='{.spec.clusterIP}')"
make proxy
com

# Create Namespace
echo "   Creating Namespace metallb-system ..."
kubectl create namespace metallb-system

# Install MetalLb
echo "   Installing MetalLb Loadbalancer ..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v${METALLBVERSION}/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v${METALLBVERSION}/manifests/metallb.yaml
kubectl -n metallb-system get all

## Set Cluster IPs
echo "   Creating MetalLb IP Pool ..."
CLUSTERIP=$(kubectl get nodes -n ${CONTROL_PLANE} -o yaml | grep "address: 1" | cut -d ":" -f 2 | cut -d " " -f 2)
#BASEIP=$(echo $ETH_IP | cut -d "." -f1-3)
BASEIP=$(echo $CLUSTERIP | cut -d "." -f1-3)
BEGINIP=${BASEIP}.100
ENDIP=${BASEIP}.200
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${BEGINIP}-${ENDIP}
EOF
kubectl get configmap -n metallb-system config -o yaml

# Setup Tailscale Subnet Router
echo "   Setting up Tailscale Subnet Router ..."
# Reference https://tailscale.com/kb/1019/subnets/
CLUSTER_CIDR=$(echo '{"apiVersion":"v1","kind":"Service","metadata":{"name":"tst"},"spec":{"clusterIP":"1.1.1.1","ports":[{"port":443}]}}' | kubectl apply -f - 2>&1 | sed 's/.*valid IPs is //')
SERVICE_CIDR="${BASEIP}.0/24"
POD_CIDR=$(kubectl get nodes -n ${CONTROL_PLANE}  -o jsonpath='{.items[*].spec.podCIDR}')
export TS_ROUTES=$CLUSTER_CIDR,$SERVICE_CIDR,$POD_CIDR
make subnet-router
ROUTERPOD=$(kubectl get po -n default | grep subnet-router | cut -d " " -f 1)
while [[ $(kubectl get po $ROUTERPOD -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "Waiting for pod $ROUTERPOD to be ready" && sleep 1; done
sleep 10s
kubectl logs subnet-router
