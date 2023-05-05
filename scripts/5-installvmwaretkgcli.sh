#!/bin/bash

#Start in tmp
cd /tmp

##Download/install VMware TKG CLI
#vmw-cli ls
echo "> Listing VMware TKG binaries on Customer Connect..."
vmw-cli ls vmware_tanzu_kubernetes_grid

#Specify variables
export VMWUSER = ${VMWUSER}
export VMWPASS = ${VMWPASS}
export TKGVERSION = ${TKGVERSION}
echo "> Using Customer Connect account $VMWUSER to download binaries..."

echo "> Downloading VMware TKG binaries from Customer Connect..."
vmw-cli cp tanzu-cli-bundle-linux-amd64.tar.gz

echo "> Extracting VMware TKG binaries..."
sudo tar -xf tanzu-cli-bundle-linux-amd64.tar.gz

echo "> Installing VMware TKG binaries..."
sudo install cli/core/v${TKGVERSION}/tanzu-core-linux_amd64 /usr/local/bin/tanzu

echo "> Initializing VMware TKG binaries..."
tanzu init

echo "> Syncing VMware TKG plugins..."
tanzu plugin sync

echo "> Listing VMware TKG plugins..."
tanzu plugin list