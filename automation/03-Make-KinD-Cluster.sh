#!/bin/bash
# Setup Local Kubernetes Cluster
echo '  Setup Kubernetes Cluster ...'

# Versions
#Version of Cert Manager to install
#Internal Domain name
DOMAIN_NAME=$(hostname -d)
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

#Open Ports
echo -e "   Opening Ingress Ports..."
sudo iptables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp -m tcp --dport 8080 -j ACCEPT
sudo iptables -I INPUT -p tcp -m tcp --dport 443 -j ACCEPT
sudo iptables-save > /etc/systemd/scripts/ip4save

#Echo Info to end user
clear
echo "Kubernetes in Docker (KinD) Cluster setup completed"
sleep 60s
