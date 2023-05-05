/*
	VMware Photon OS Variables File
	Created by 
		Russell Hamker
		Twitter -> @butch7903
*/

// VM Config Info
version = "1.0.0"
description = "Hamker Tech Photon Tanzu TKG Appliance"
vm_name = "photontkg-template.hamker.local"
vm_final_name = "photontkg.hamker.local"
iso_checksum = "f6d95f3e88a1380bb168b9d0a1a2bf85" #md5 checksum
iso_url = "https://packages.vmware.com/photon/5.0/GA/iso/photon-minimal-5.0-dde71ec57.x86_64.iso"
numvcpus = "2"
ramsize = "1024"

// VMware Connect Credentials # needed to download Tanzu CLI
vmwuser = "<YourEmailHere@Domain.com>"
vmwpass = "<YourCustomerConnectPassword>"

// VM user Login Info
guest_username = "root"
guest_password = "VMware12345!"

// VMHOST Info
builder_host = "10.10.0.11"
builder_host_username = "root"
builder_host_password = "VMware12345!"
builder_host_datastore = "vsanDatastore"
builder_host_portgroup = "VM Network"

// VCSA Info
ovftool_deploy_vcenter = "10.10.0.100"
ovftool_deploy_vcenter_password = "VMware12345!"
ovftool_deploy_vcenter_username ="administrator@vsphere.local"

// OVA OVF Template Name
photon_ovf_template = "photon.xml.template"
