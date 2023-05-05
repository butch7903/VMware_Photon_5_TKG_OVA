#!/bin/bash
# Setup Prometheus and Grafana
# https://tanzucommunityedition.io/docs/v0.12/docker-monitoring-stack/
echo '  Preparing for Prometheus and Grafana ...'

# Versions
#Version of Cert Manager to install
#CERT_MANAGER_PACKAGE_VERSION="1.8.0"
CERT_MANAGER_PACKAGE_VERSION="1.7.2+vmware.1-tkg.1"
#Version of Contour/Envoy to install
#CONTOUR_PACKAGE_VERSION="1.20.1"
CONTOUR_PACKAGE_VERSION="1.20.2+vmware.1-tkg.1"
#Version of Local Path Storage to install
LOCAL_PATH_STORAGE_PACKAGE_VERSION="0.0.20"
#Version of Prometheus to install
#PROMETHEUS_PACKAGE_VERSION="2.27.0-1"
PROMETHEUS_PACKAGE_VERSION="2.36.2+vmware.1-tkg.1"
#Version of Grafana to install
#GRAFANA_PACKAGE_VERSION="7.5.11"
GRAFANA_PACKAGE_VERSION="7.5.16+vmware.1-tkg.1"
#Internal Domain name
DOMAIN_NAME=$(hostname -d)
#Internal DNS Entry to that resolves to the prometheus fqdn - you must make this DNS Entry
PROMETHEUS_FQDN="prometheus.${DOMAIN_NAME}"
#Internal DNS Entry to that resolves to the grafana fqdn - you must make this DNS Entry
GRAFANA_FQDN="grafana.${DOMAIN_NAME}"
#Grafana default admin password
GRAFANA_ADMIN_PASSWORD='VMware12345!'
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

<<comment
# Install Local Path Storage
echo "   Installing Local Path Storage version ${LOCAL_PATH_STORAGE_PACKAGE_VERSION} ..."
tanzu package available list local-path-storage.community.tanzu.vmware.com
tanzu package install local-path-storage --package-name local-path-storage.community.tanzu.vmware.com --version ${LOCAL_PATH_STORAGE_PACKAGE_VERSION}
tanzu package installed list -n default

#Validate Package is Running
PNAME="local-path-storage"
PACKAGE="local-path-storage"
CSTATUS='NotRunning'
echo "   Validating $PNAME is ready ..."
while [[ $CSTATUS != "Running" ]]
do
echo "$PNAME - NotRunning"
APPNAME=$(kubectl -n $PACKAGE get po -o name | cut -d '/' -f 2)
CSTATUS=$(kubectl get po -n $PACKAGE | grep $APPNAME | awk '{print $3}')
done
echo "$PNAME - $CSTATUS"
kubectl get po -n $PACKAGE | grep $APPNAME

#Validate Tanzu Package is reconciled
PNAME="local-path-storage"
PACKAGE="local-path-storage"
CSTATUS='NotReconziled'
echo "   Validating $PNAME is reconciled ..."
while [[ $CSTATUS != "Reconcile succeeded" ]]
do
echo "$PNAME not reconciled"
CSTATUS=$(tanzu package installed get $PACKAGE | grep STATUS | awk '{print $2" "$3}')
sleep 5s
done
echo "$PNAME $CSTATUS"
tanzu package installed get $PACKAGE
sleep 20s

#Set Local-Storage-Path as default
echo "   Setting local-storage-path as the default storageclass ..."
kubectl patch storageclass standard -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
kubectl get sc
comment

# Prepare Install Prometheus
echo "   Preparing for Prometheus version ${PROMETHEUS_PACKAGE_VERSION} ..."
#tanzu package available list prometheus.community.tanzu.vmware.com
tanzu package available list prometheus.tanzu.vmware.com
echo '   Downloading Prometheus files...'
image_url=$(kubectl get packages prometheus.tanzu.vmware.com.${PROMETHEUS_PACKAGE_VERSION} -o jsonpath='{.spec.template.spec.fetch[0].imgpkgBundle.image}')
imgpkg pull -b $image_url -o /tmp/prometheus-package
cp /tmp/prometheus-package/config/values.yaml prometheus-data-values.yaml
SEDINPUT='s/virtual_host_fqdn: "prometheus.system.tanzu"/virtual_host_fqdn: "'$PROMETHEUS_FQDN'"/g'
sed -i "$SEDINPUT" prometheus-data-values.yaml
sed -i "s/ enabled: false/ enabled: true/g" prometheus-data-values.yaml
echo '   Removing comments in prometheus-data-values.yaml file ...'
yq -i eval '... comments=""' prometheus-data-values.yaml
# Install Prometheus
echo "   Installing Prometheus version ${PROMETHEUS_PACKAGE_VERSION} ..."
tanzu package install prometheus -p prometheus.tanzu.vmware.com -v ${PROMETHEUS_PACKAGE_VERSION} --values-file prometheus-data-values.yaml

#Validate Tanzu Package is reconciled
PNAME="prometheus"
PACKAGE="prometheus"
CSTATUS='NotReconziled'
echo "   Validating $PNAME is reconciled ..."
while [[ $CSTATUS != "Reconcile succeeded" ]]
do
echo "    $PNAME not reconciled"
CSTATUS=$(tanzu package installed get $PACKAGE | grep STATUS | awk '{print $2" "$3}')
sleep 5s
done
echo "    $PNAME $CSTATUS"

#Validate Package is Running
PNAME="prometheus"
PACKAGE="prometheus"
CSTATUS='NotRunning'
echo "   Validating $PNAME is ready ..."
while [[ $CSTATUS != "Running" ]]
do
echo "   $PNAME - NotRunning"
APPNAME=$(kubectl -n $PACKAGE get po -l app=$PACKAGE -o name | grep prometheus-server | cut -d '/' -f 2)
CSTATUS=$(kubectl get po -n $PACKAGE | grep $APPNAME | awk '{print $3}')
done
echo "   $PNAME - $CSTATUS"
kubectl get po -n $PACKAGE | grep $APPNAME

#List storage of Prometheus
kubectl get pvc -A

#List Promethus Pods and services
kubectl get pods,svc -n prometheus

#Validate HTTPProxy for Prometheus
kubectl get HTTPProxy -n prometheus

#Get HTTPProxy Port for Prometheus
PACKAGE="prometheus"
APPNAME=$(kubectl -n $PACKAGE get po -l app=$PACKAGE -o name | grep prometheus-server | cut -d '/' -f 2)
kubectl get pods $APPNAME -n prometheus -o jsonpath='{.spec.containers[*].name}{.spec.containers[*].ports}'

#validate prometheus is accessible
curl -Lk https://$HOSTNAME

# Prepare for Grafana
echo "   Preparing for Grafana version ${GRAFANA_PACKAGE_VERSION} ..."
tanzu package available list grafana.tanzu.vmware.com
echo '   Downloading Grafana files...'
image_url=$(kubectl get packages grafana.tanzu.vmware.com.${GRAFANA_PACKAGE_VERSION} -o jsonpath='{.spec.template.spec.fetch[0].imgpkgBundle.image}')
imgpkg pull -b $image_url -o /tmp/grafana-package
cp /tmp/grafana-package/config/values.yaml grafana-data-values.yaml
#modify grafana yaml
echo "   Modifying Grafana yaml file..."
SEDINPUT='s/virtual_host_fqdn: "grafana.system.tanzu"/virtual_host_fqdn: "'$GRAFANA_FQDN'"/g'
sed -i "$SEDINPUT" grafana-data-values.yaml
sed -i "s/ enabled: false/ enabled: true/g" grafana-data-values.yaml
GRAFANA_BASE64_ADMIN_PASSWORD=$( echo -n "$GRAFANA_ADMIN_PASSWORD" | base64 )
SEDINPUT='s/admin_password: ""/admin_password: "'$GRAFANA_BASE64_ADMIN_PASSWORD'"/g' 
sed -i "$SEDINPUT" grafana-data-values.yaml
echo '   Removing comments in grafana-data-values.yaml file ...'
yq -i eval '... comments=""' grafana-data-values.yaml
sed -i "s/type: LoadBalancer/type: ClusterIP/g" grafana-data-values.yaml
# Install Grafana
echo "   Installing Grafana version ${GRAFANA_PACKAGE_VERSION} ..."
tanzu package install grafana \
   --package-name grafana.tanzu.vmware.com \
   --version ${GRAFANA_PACKAGE_VERSION} \
   --values-file grafana-data-values.yaml
   
#Get HTTPProxy Port for grafana
PACKAGE="grafana"
APPNAME=$(kubectl -n $PACKAGE get po -L app=$PACKAGE | grep grafana | cut -d ' ' -f 1)
kubectl get pods $APPNAME -n $PACKAGE -o jsonpath='{.spec.containers[*].name}{.spec.containers[*].ports}'

#Validate Tanzu Package is reconciled
PNAME="grafana"
PACKAGE="grafana"
CSTATUS='NotReconziled'
echo "   Validating $PNAME is reconciled ..."
while [[ $CSTATUS != "Reconcile succeeded" ]]
do
echo "    $PNAME not reconciled"
CSTATUS=$(tanzu package installed get $PACKAGE | grep STATUS | awk '{print $2" "$3}')
sleep 5s
done
echo "    $PNAME $CSTATUS"

#Validate Package is Running
PNAME="grafana"
PACKAGE="grafana"
CSTATUS='NotRunning'
echo "   Validating $PNAME is ready ..."
while [[ $CSTATUS != "Running" ]]
do
echo "    $PNAME - NotRunning"
APPNAME=$(kubectl -n $PACKAGE get po -L app=$PACKAGE | grep grafana | cut -d ' ' -f 9)
CSTATUS=$(kubectl get po -n $PACKAGE | grep $APPNAME | awk '{print $3}')
done
echo "    $PNAME - $CSTATUS"
kubectl get po -n $PACKAGE | grep $APPNAME

#Open Ports
echo -e "   Opening Ingress Ports..."
#sudo iptables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT
#sudo iptables -I INPUT -p tcp -m tcp --dport 8080 -j ACCEPT
sudo iptables -I INPUT -p tcp -m tcp --dport 443 -j ACCEPT
sudo iptables-save > /etc/systemd/scripts/ip4save

#Echo Info to end user
clear
echo "You can now access the Prometheus at:"
echo "					     https://$PROMETHEUS_FQDN"
echo "You can now access the Grafana at:"
echo "					  https://$GRAFANA_FQDN"
echo "Grafana Username: admin"
echo "Grafana Password: $GRAFANA_ADMIN_PASSWORD"
echo "Note you must either have a DNS A record in your DNS or a /etc/host entry added for the hostname $PROMETHEUS_FQDN and $GRAFANA_FQDN pointing to the external IP of your Tanzu Kubernetes Cluster"
echo "Prometheus website & documentation can be found here: https://prometheus.io"
echo "Grafana website & documentation can be found here: https://grafana.com"
sleep 60s
