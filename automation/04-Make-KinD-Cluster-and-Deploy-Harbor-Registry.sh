#!/bin/bash
# Setup Harbor Registry
echo '  Preparing for Harbor Registry ...'

# Versions
#Version of Cert Manager to install
#CERT_MANAGER_PACKAGE_VERSION=1.8.0
CERT_MANAGER_PACKAGE_VERSION="1.7.2+vmware.1-tkg.1"
#Version of Contour/Envoy to install
#CONTOUR_PACKAGE_VERSION=1.20.1
CONTOUR_PACKAGE_VERSION="1.20.2+vmware.1-tkg.1"
#Version of Harbor to install
#HARBOR_PACKAGE_VERSION=2.4.2
HARBOR_PACKAGE_VERSION="2.5.3+vmware.1-tkg.1"
#Harbor Admin Password
HARBOR_ADMIN_PASSWORD='VMware12345!'
#Internal Domain name
DOMAIN_NAME=$(hostname -d)
#Internal DNS Entry to that resolves to the harbor fqdn - you must make this DNS Entry
HARBOR_FQDN="harbor.${DOMAIN_NAME}"
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

# Add Package Repository
echo "   Adding Tanzu Package Repository..."
tanzu package repository add standard --url projects.registry.vmware.com/tkg/packages/standard/repo:v1.6.0 

# Install Cert Manager
echo "   Installing Cert Manager version ${CERT_MANAGER_PACKAGE_VERSION}..."
# https://tanzucommunityedition.io/docs/v0.12/package-readme-cert-manager-1.8.0/
#tanzu package available list cert-manager.community.tanzu.vmware.com
#tanzu package install cert-manager --package-name cert-manager.community.tanzu.vmware.com --version ${CERT_MANAGER_PACKAGE_VERSION}
# https://docs.vmware.com/en/VMware-Tanzu-Kubernetes-Grid/2/using-tkg-2/GUID-packages-cert-mgr.html
tanzu package available list cert-manager.tanzu.vmware.com -A
tanzu package install cert-manager --package-name cert-manager.tanzu.vmware.com --version ${CERT_MANAGER_PACKAGE_VERSION}
tanzu package installed list -n default

#Validate Package is Running
PNAME="Cert Manager"
PACKAGE="cert-manager"
CSTATUS='NotRunning'
echo "   Validating $PNAME is ready ..."
while [[ $CSTATUS != "Running" ]]
do
echo "   $PNAME - NotRunning"
APPNAME=$(kubectl -n $PACKAGE get po -l app=$PACKAGE -o name | cut -d '/' -f 2)
CSTATUS=$(kubectl get po -n $PACKAGE | grep $APPNAME | awk '{print $3}')
done
echo "$PNAME - $CSTATUS"
kubectl get po -n $PACKAGE | grep $APPNAME

#Validate Tanzu Package is reconciled
PNAME="Cert Manager"
PACKAGE="cert-manager"
CSTATUS='NotReconziled'
echo "> Validating $PNAME is reconciled..."
while [[ $CSTATUS != "Reconcile succeeded" ]]
do
echo "   $PNAME not reconciled"
CSTATUS=$(tanzu package installed get $PACKAGE | grep STATUS | awk '{print $2" "$3}')
done
echo "$PNAME $CSTATUS"
tanzu package installed get $PACKAGE | grep STATUS
sleep 20s

# Install Contour
echo "   Installing Contour version ${CONTOUR_PACKAGE_VERSION} ..."
# https://tanzucommunityedition.io/docs/v0.12/package-readme-contour-1.20.1/
#tanzu package available list contour.community.tanzu.vmware.com
tanzu package available list contour.tanzu.vmware.com
cat <<EOF >contour-values.yaml
envoy:
  service:
    type: ClusterIP
  hostPorts:
    enable: true
EOF
tanzu package install contour \
  --package-name contour.tanzu.vmware.com \
  --version ${CONTOUR_PACKAGE_VERSION} \
  --values-file contour-values.yaml

#Validate Tanzu Package is reconciled
PNAME="projectcontour"
PACKAGE="contour"
CSTATUS='NotReconziled'
echo "   Validating $PNAME is reconciled ..."
while [[ $CSTATUS != "Reconcile succeeded" ]]
do
echo "   $PNAME not reconciled"
CSTATUS=$(tanzu package installed get $PACKAGE | grep STATUS | awk '{print $2" "$3}')
sleep 5s
done
echo "   $PNAME $CSTATUS"
sleep 20s

# Install Harbor
echo "   Preparing for Harbor Registry version ${HARBOR_PACKAGE_VERSION} ..."
# https://tanzucommunityedition.io/docs/v0.12/package-readme-harbor-2.4.2/
echo "   Downloading Harbor Registry files ..."
image_url=$(kubectl get packages harbor.tanzu.vmware.com.${HARBOR_PACKAGE_VERSION} -o jsonpath='{.spec.template.spec.fetch[0].imgpkgBundle.image}')
imgpkg pull -b $image_url -o /tmp/harbor-package
cp /tmp/harbor-package/config/values.yaml harbor-values.yaml
cp /tmp/harbor-package/config/scripts/generate-passwords.sh .
echo "   Generating Secrets/Passwords for Harbor-values.yaml file ..."
bash generate-passwords.sh harbor-values.yaml
#set harbor initial password
sudo sed -i "s/harborAdminPassword:.*/harborAdminPassword: ${HARBOR_ADMIN_PASSWORD}/g" harbor-values.yaml
SET_HARBOR_ADMIN_PASSWORD=$(less harbor-values.yaml | grep harborAdminPassword)
echo "   Harbor Admin Password will be $SET_HARBOR_ADMIN_PASSWORD"
echo "   Removing comments in Harbor-values.yaml file..."
yq -i eval '... comments=""' harbor-values.yaml
#echo '> Setting Hostname Harbor-values.yaml file...'
sudo sed -i "s/harbor.yourdomain.com/${HARBOR_FQDN}/g" harbor-values.yaml
echo "   Updating /etc/hosts with harbor info..."
echo "   $IPADDRS harbor.yourdomain.com notary.harbor.yourdomain.com..." >> /etc/hosts
echo "   Installing Harbor Registry..."
tanzu package install harbor \
   --package-name harbor.tanzu.vmware.com \
   --version ${HARBOR_PACKAGE_VERSION} \
   --values-file harbor-values.yaml
   
#Validate Tanzu Package is reconciled
PNAME="harbor"
PACKAGE="harbor"
CSTATUS='NotReconziled'
echo "   Validating $PNAME is reconciled ..."
while [[ $CSTATUS != "Reconcile succeeded" ]]
do
echo "   $PNAME not reconciled..."
CSTATUS=$(tanzu package installed get $PACKAGE | grep STATUS | awk '{print $2" "$3}')
sleep 5s
done
echo "   $PNAME $CSTATUS..."

#Open Ports
echo -e "   Opening Ingress Ports..."
#sudo iptables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT
#sudo iptables -I INPUT -p tcp -m tcp --dport 8080 -j ACCEPT
sudo iptables -I INPUT -p tcp -m tcp --dport 443 -j ACCEPT
sudo iptables-save > /etc/systemd/scripts/ip4save

#Echo Info to end user
clear
HARBOR_PORT=$(less harbor-values.yaml | grep "  https:" | cut -d ':' -f 2 | cut -d ' ' -f2)
echo "You can now access the Harbor Registry at:"
echo "						  https://$HARBOR_FQDN"
echo "Harbor Username: admin"
echo "Harbor Password: $HARBOR_ADMIN_PASSWORD"
echo "Note you must either have a DNS A record in your DNS or a /etc/host entry added for the hostname $HARBOR_FQDN"
echo "Harbor website & documentation can be found here: https://goharbor.io"
sleep 60s
