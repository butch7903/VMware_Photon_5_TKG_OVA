#!/bin/bash
# Setup EMBY Using Contour
echo '  Preparing for Emby ...'
# Reference https://artifacthub.io/packages/helm/k8s-at-home/emby

# Versions
#CERT_MANAGER_PACKAGE_VERSION=1.8.0
CERT_MANAGER_PACKAGE_VERSION="1.7.2+vmware.1-tkg.1"
#Version of Contour/Envoy to install
#CONTOUR_PACKAGE_VERSION=1.20.1
CONTOUR_PACKAGE_VERSION="1.20.2+vmware.1-tkg.1"
#Internal Domain name
DOMAIN_NAME=$(hostname -d)
#Internal DNS Entry to that resolves to the EMBY fqdn - you must make this DNS Entry
EMBY_FQDN="emby.${DOMAIN_NAME}"
#EMBY Admin Password
EMBY_ADMIN_PASSWORD='VMware12345!'
#Tanzu/Kubernetes cluster name
CLUSTER_NAME='local-cluster'
#Control Plane Name
CONTROL_PLANE="$CLUSTER_NAME"-control-plane
#Location Name
USERD=root
# Github Variables for YAML files
REPO="https://github.com/guarddog-dev"
REPONAME="VMware_Photon_OVA"
REPOFOLDER="yaml"

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

# Get Timezone from OVA
export TZ=$(timedatectl status | grep "Time zone" | cut -d ":" -f 2 | cut -d " " -f 2)
echo "   System Timezone is $TZ ..."

# Create emby.yaml
echo "   Creating emby yaml file ..."
cat <<EOF > /root/automation/emby.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: emby
  labels:
    name: emby
---
apiVersion: v1
kind: PersistentVolume
metadata:
  finalizers:
  - kubernetes.io/pv-protection
  name: emby-config
spec:
  accessModes:
  - ReadWriteOnce
  capacity:
    storage: 20Gi
  claimRef:
    apiVersion: v1
    kind: PersistentVolumeClaim
    name: emby-config
    namespace: emby
  hostPath:
    path: /var/local-path-provisioner/pvc-emby-config
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - local-cluster-control-plane
  persistentVolumeReclaimPolicy: Delete
  storageClassName: standard
  volumeMode: Filesystem
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  finalizers:
  - kubernetes.io/pvc-protection
  name: emby-config
  namespace: emby
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: standard
  volumeMode: Filesystem
  volumeName: emby-config
---
#@ load("@ytt:data", "data")
apiVersion: v1
kind: Pod
metadata:
  name: emby
  namespace: emby
spec:
  automountServiceAccountToken: true
  containers:
  - env:
    - name: TZ
      value: #@ data.values.TIMEZONE
    image: emby/embyserver:latest
    imagePullPolicy: IfNotPresent
    livenessProbe:
      failureThreshold: 3
      periodSeconds: 10
      successThreshold: 1
      tcpSocket:
        port: 8096
      timeoutSeconds: 1
    name: emby
    ports:
    - containerPort: 8096
      hostPort: 8096
      name: http
      protocol: TCP
    - containerPort: 8920
      hostPort: 8920
      name: https
      protocol: TCP
    readinessProbe:
      failureThreshold: 3
      periodSeconds: 10
      successThreshold: 1
      tcpSocket:
        port: 8096
      timeoutSeconds: 1
    volumeMounts:
    - mountPath: /config
      name: config
    - mountPath: /mnt/media
      name: emby-media
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: emby-config
    - name: emby-media
      hostPath:
        type: DirectoryOrCreate
        path: /mnt/emby-media
---
apiVersion: v1
kind: Service
metadata:
  name: emby
  namespace: emby
spec:
  internalTrafficPolicy: Cluster
  ipFamilies:
  - IPv4
  ipFamilyPolicy: SingleStack
  ports:
  - name: http
    port: 8096
    protocol: TCP
    targetPort: http
  - name: https
    port: 8920
    protocol: TCP
    targetPort: https
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: emby-web
  namespace: emby
spec:
  rules:
  - host:
    http:
      paths:
      - pathType: Prefix
        path: /
        backend:
          service:
            name: emby
            port:
              number: 8096
EOF

# Deploy pod
echo "   Deploying Emby via yaml file ..."
ytt -f /root/automation/emby.yaml -v TIMEZONE=$TZ | kubectl apply -f-

# Validate that EMBY pod is ready
echo "   Validate that emby pod in namespace emby is ready ..."
EMBYPOD=$(kubectl get po -n emby | grep emby | cut -d " " -f 1)
while [[ $(kubectl get po -n emby $EMBYPOD -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "   Waiting for pod $EMBYPOD to be ready ..." && sleep 10s; done
echo "   Pod $EMBYPOD is now ready ..."

# Echo pod info
echo "   Info on new pod includes:"
kubectl get pods -n emby -o wide
kubectl get pv,pvc -n emby
kubectl get services -n emby -o wide
#kubectl logs $(EMBYPOD) -n emby --all-containers
echo " "

kubectl get all,ingress -n emby

#Open Ports
echo -e "   Opening Ingress Ports..."
sudo iptables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp -m tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p tcp -m tcp --dport 8096 -j ACCEPT
sudo iptables-save > /etc/systemd/scripts/ip4save

# Echo Completion
sleep 10s
clear
echo "   EMBY pod deployed ..."
echo "   You can access EMBY by going to:"
echo "                                      http://$EMBY_FQDN/8096"
echo " "
echo "   Note: You must make a DNS or HOST File entry for $EMBY_FQDN to be able to be accessed."
echo "   Note: You will need to have 20Gi of space on your kubernetes appliance for emby db/logs."
sleep 60s
