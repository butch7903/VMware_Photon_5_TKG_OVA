#!/bin/bash

##Download/Install VMW-CLI Utility (used to download packages from customerconnect.vmware.com)
echo "> Downloading vmw-cli github repo..."
cd /tmp
git clone https://github.com/apnex/vmw-cli.git --depth 1
cd vmw-cli/
sudo chmod 755 vmw-cli

echo "> Installing vmw-cli in /usr/local/bin..."
sudo cp vmw-cli /usr/local/bin/vmw-cli

echo "> Testing vmw-cli..."
vmw-cli ls