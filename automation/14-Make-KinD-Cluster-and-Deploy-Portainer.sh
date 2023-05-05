#!/bin/bash
# Setup Portainer
echo '  Preparing for Portainer ...'
# Reference: https://www.portainer.io/

# Versions
#Internal Domain name
DOMAIN_NAME=$(hostname -d)
#Tanzu/Kubernetes cluster name
CLUSTER_NAME='local-cluster'
#Control Plane Name
CONTROL_PLANE="$CLUSTER_NAME"-control-plane
#Location Name
USERD=root
THEHOSTNAME=$(hostname)

# Disable DNS Resolver on system
echo '   Disabling system-d resolved service ...'
sudo systemctl disable systemd-resolved
sudo systemctl stop systemd-resolved

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
  - containerPort: 9443
    hostPort: 9443
    protocol: TCP
  - containerPort: 30776
    hostPort: 30776
    protocol: TCP
  - containerPort: 30777
    hostPort: 30777
    protocol: TCP
  - containerPort: 30779
    hostPort: 30779
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

## Install Portainer
echo "   Adding helm repo for portainer deployment ..."
helm repo add portainer https://portainer.github.io/k8s/
helm repo update

# Create Namespace portainer
echo "   Creating Namespace portainer ..."
kubectl create namespace portainer

# Install Portainer
echo "   Using helm to install portainer ..."
helm install --create-namespace -n portainer portainer portainer/portainer

# Validate that the pod is ready
echo "   Validate that portainer pod is ready ..."
THENAMESPACE="portainer"
THEPOD=$(kubectl get po -n $THENAMESPACE | grep portainer | cut -d " " -f 1)
while [[ $(kubectl get po -n $THENAMESPACE $THEPOD -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "Waiting for pod $THEPOD to be ready" && sleep 1; done
echo "   Pod $THEPOD is now ready ..."

# Show portainer pod info
echo "   portainer pod info: ..."
kubectl get pods -n $THENAMESPACE -o wide
kubectl get services -n $THENAMESPACE -o wide
kubectl describe services -n $THENAMESPACE
kubectl get ingress -n $THENAMESPACE -A

# Echo Completion
sleep 10s
IP_ADDRESS=$(/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
clear
echo "   Portainer pod is deployed ..."
echo "   You can access portainer by going to:"
echo "                                      https://$THEHOSTNAME:30779"
echo "                                      or"
echo "                                      https://$IP_ADDRESS:30779"
echo " "
echo "   Note: You must make a DNS or HOST File entry for $THEHOSTNAME to be able to be accessed"
echo "   More info can be found at https://www.portainer.io/"

sleep 60s
