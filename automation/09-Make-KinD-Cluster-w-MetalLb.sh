#!/bin/bash
# Setup Cluster and MetalLb
echo '  Preparing for MetalLb ...'

# Versions
#Internal Domain name
DOMAIN_NAME=$(hostname -d)
#Tanzu/Kubernetes cluster name
CLUSTER_NAME='local-cluster'
#Control Plane Name
CONTROL_PLANE="$CLUSTER_NAME"-control-plane
#Location Name
USERD=root

# Find if variable exists
echo '   Checking if Kubernetes VIP exists ...'
ETH_IP=$(/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')

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
  - containerPort: 8096
    hostPort: 8096
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

## Install MetalLB (load-balancer)
METALLBVERSION=0.12.1
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v${METALLBVERSION}/manifests/namespace.yaml
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v${METALLBVERSION}/manifests/metallb.yaml
kubectl -n metallb-system get all

## Set Cluster IPs
CLUSTERIP=$(kubectl get nodes -n local-cluster-control-plane -o yaml | grep "address: 1" | cut -d ":" -f 2 | cut -d " " -f 2)
#BASEIP=$(echo $ETH_IP | cut -d "." -f1-3)
BASEIP=$(echo $CLUSTERIP | cut -d "." -f1-3)
BEGINIP=${BASEIP}.201
ENDIP=${BASEIP}.210
cat <<EOF > metallb.yaml
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
kubectl create -f metallb.yaml
kubectl get configmap -n metallb-system config -o yaml

# Echo Completion
sleep 10s
#IP_ADDRESS=$(/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
clear
echo "   MetalLb pod deployed ..."
sleep 60s
