# Infrastructure

## Hardware
- (9) PCs, each group of 3 should be identical
- (18) patch cords
- 24-port managed ethernet switch
- (9) USB 3.0 Ethernet Adapters
- USB 3.0 Flash Drive - 8GB+, if formatted ext4/exFAT/FAT32 does not need reformatted (Slackware Files USB Drive)
- USB Flash Drive - any size, will be erased (Slackware Boot USB Drive)

## Static Mirror

### Initial Download

The first thing we need to do is create a static image of the Slackware-current mirror. Since the mirror updates as much as daily, we need a local static copy. Since we don't necessarily have a Slackware computer at this point, let's make this as OS agnostic as possible. Slackware can be downloaded with rsync. This should work on Windows (with WSL), Linux, or Mac OS.

On Linux:
```bash
sudo mkdir -p /mnt/usb
sudo mount /dev/sdc1 /mnt/usb
sudo rsync -havP --delete --delete-after  --no-o --no-g --safe-links  --timeout=60 --contimeout=30 --exclude "EFI/*" --exclude "extra/*" --exclude "pasture/*" --exclude "patches/*"  --exclude "source/*"  --exclude "testing/*" rsync://mirrors.kernel.org/slackware/slackware64-current /mnt/usb
```
![Screenshot of commands for Linux](mirror-rsync-linux.png)
![Screenshot of commands for Linux after completion](mirror-rsync-linux-finished.png)

On Windows (WSL):
```bash
sudo mount -t drvfs J: /mnt/j
sudo rsync -havP --delete --delete-after  --no-o --no-g --safe-links  --timeout=60 --contimeout=30 --exclude "EFI/*" --exclude "extra/*" --exclude "pasture/*" --exclude "patches/*"  --exclude "source/*"  --exclude "testing/*" rsync://mirrors.kernel.org/slackware/slackware64-current /mnt/j
```
![Screenshot of commands for Windows](mirror-rsync-wsl.png)
![Screenshot of commands for Windows after completion](mirror-rsync-wsl-finished.png)


### Slackware Installer USB

Since there is not infrastructure at this point, we need to create a USB flash drive to use to install Slackware onto the build node. To do this we need to write `slackware64-current/usb-and-pxe-installers/usbboot.img` to a USB drive. On a Unix-like OS, this can be done with `dd`. On Windows, this should probably be done with a program like Rufus.

```
mount -t ntfs3 /dev/sdc1 /mnt/usb
dd if=/mnt/usb/slackware64-current/usb-and-pxe-installers/usbboot.img of=/dev/sdd status=progress bs=4096
```

### Slackware Static Mirror USB

You also need to copy the Slackware files to another USB flash drive. That drive can be formatted as FAT32 or ext4.

## Build Node

Now, boot the installer USB on the build node. My process for installing Slackware is documented elsewhere so that process won't be covered here. For the purposes of the build station, install package series a, ap, d, k, l, n, tcl, x, xap, and xfce. Choose the `terse` install option to install the default package set. On the build station, it's probably best to just install to one large ext4 partition as the build node should be considered disposable.

### Cluster Administration Account

Once the system is booted (or during install), you will need to create the cluster account. We'll call the cluster account `clusteradm` and use a UID of 1050. This will be consistent on all cluster members. This account will be used for Ansible and general cluster administration.

```
# As root, since there are no other accounts
useradd -d /home/clusteradm -g users -u 1050 -m -s /bin/bash clusteradm
```

In addiition, we need to grant `sudo` access to the `clusteradm` account. The path includes `go` - it is not yet installed, but will be soon. Edit `/etc/sudoers.d/clusteradm` as follows:

```
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/go/bin"
clusteradm ALL=(ALL:ALL) ALL
```

Make sure to set a password on the clusteradm account.

```
passwd clusteradm
```

### build-system

#### Download

Now that the OS install is complete, SSH into the build node as `clusteradm`. We need to install my custom build-system. The build-system is a script that sets up a local Jenkins and Semaphore instance.

```bash
git clone https://github.com/scottr131/build-system.git
```

#### Configure

Now, configure and start the build system. You will need to create a DNS wildcard record to your build server. *.<servername> should resolve to your build server.

```bash
cd build-system
# Download binaries
./build-system.sh download all
# Create directories
./build-system.sh setup dirs
# Set up JDKs
./build-system.sh setup jdk
# Setup the auth system and reverse proxy
# You will be prompted for a username and password
./build-system.sh setup rp
./build-system.sh setup jenkins
```

#### Start

Next, start the reverse proxy and Jenkins. The reverse proxy requires `sudo` so that it can bind to port 443.

```bash
./build-system.sh start jenkins
./build-system.sh start rp # Requires sudo
```

#### Jenkins Configuration

After Jenkins starts it will generate an initial password. You can obtain that password for the next step with `cat /home/clusteradm/build-system/jenkins/secrets/initialAdminPassword`

Finally, in a web browser, go to the Jenkins instance at `https://jenkins.<your-server>.<domain>`. You will recieve two certificate warnings because of self signed certificates. One is for the Authelia certficiate and one is for the Jenkins certificate. Bypass these errors and you should get an Authelia login page. Login with the reverse proxy account created earlier. Make sure to check "Remember me" if you are on your local LAN.

Jenkins will prompt you for the initial passowrd that you obtained above. Jenkins will then prompt for what plugins you want to install. Choose "Install suggested plugins." Go ahead and create a "First Admin User" account in Jenkins once the plugin install is complete. On the next page, make sure the Jenkins URL is correct and save your configuration. Jenkins is now configured and we are (almost) ready to start building software.

Slackbuilds need to run as root. Since our build system is disposable, we are going to temporarily allow `clusteradm` to sudo without a password. This is also a good time to add the path for Go if you did not add it earlier. Edit `/etc/sudoers.d/clusteradm`.

```
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/go/bin"
clusteradm ALL=(ALL:ALL) NOPASSWD: ALL
```

We can remove the "NOPASSWD:" tag after the software builds are complete.

#### Build prerequisites

Now, we need to add a job to build the "dev-tools". This includes packaging Go and JDK binaries as Slackware packages. These Go and JDK packages are needed to build other software. This is the basic process to create the job. It will only be documented here. Other jobs are similar.

In Jenkins, click "+ New Item". Call the new item "dev-tools" and choose "Pipeline" as the type. The job will created. In the General configuration, under "Pipeline", set "Definition" to "Pipeline script from SCM". Set "SCM" to "Gitb" and repository URL to "https://github.com/scottr131/slackbuilds.git". Under "Branches to build" set "Branch Specifier" to `*/main`. Set "Script Path" to `dev-tools.Jenkinsfile`. Save the job and build it.

The dev-tools do not install as part of the Jenkinsfile. To build the software needed for the cluster, we'll need to install Go and JDK 21 on the build node to build the rest of the software. 

```bash
# Note that <build number> may change depending on
# how many builds you perform
cd ~build-system/jenkins/jobs/dev-tools/builds/<build number>/archive/

# Note that package versions may change
sudo installpkg go-1.27.0-x86_64-1_SBo.txz temurin-jdk21-21.0.12.1+1-x86_64-1_SBo.txz
```

The yarn build system also needs installed. Yarn can be installed via npm corepack. This is required for the incus-stack to build correctly.

```bash
sudo npm install -g corepack
```

#### Build Software Stacks

Now, we can go back to Jenkins and build an install additional package "stacks". Next will be the management tools. Click " + New Item". Call the new item "mgmt-tools" and instead of choosing an item type, click "Duplicate and existing item." Type "dev-tools" and click OK. The job will created with the settings from dev-tools. Change "Script Path" to `mgmt-tools.Jenkinsfile`. Save the job and build it. Continue with these additional stacks. This is a recommended build order. Make sure Ceph is built before QEMU, otherwise the order isn't really important.

- mgmt-tools (Ansible, OpenTofu)
- storage-stack (LINSTOR, ZFS, DRBD)
- ovn-stack (Open vSwitch and OVN)
- incus-stack (Incus and support tools)
- ceph-stack (Ceph)
- qemu-stack (QEMU and support libraries)

Note - Ceph takes about 90 minutes to build on a decent computer. You will need at least 16GB of RAM (probably more) to compile Ceph.

### Install Incus on Build Node
Incus can be installed manually or with Ansible. Ansible is preferred. Perform one set of steps only.

#### Incus on Build Node (with Ansbile)
The next step is create a deployment node that will used to network boot and deploy software to the other nodes. The deployment node will be a virtual machine, so we need to get Incus running on the build node. To do this, we need to install the packages from qemu-stack and incus-stack. Since this build of Qemu depends on Ceph, ceph-stack will need installed too. We'll do this using the same Ansible playbooks that will be used for node deployment. First, install Ansible.

```bash
sudo installpkg ~/build-system/jenkins/workspace/mgmt-tools/ansible*.txz
```

Now clone the ansible playbooks into the `build-system` directory.
```bash
cd ~/build-system
git clone https://github.com/scottr131/ansible.git --depth=1
```

Create a basic Ansible inventory. Edit `~/build-system/ansible/hosts.ini`:
```
[deploynode]
buildhost ansible_user=clusteradm ansible_host=localhost
```

Generate a host key and trust it
```bash
ssh-keygen
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
```

Create an API key in Jenkins. Edit the script to reflect your API key. Collect packages.
```bash
./collect_packages-api.sh ceph-stack dev-tools incus-stack mgmt-tools ovn-stack qemu-stack storage-stack utils-stack
```

Config files are currently stored in a seperate repository. Clone that and copy the config files into the ansible directory.
```bash
cd ~/build-system
git clone https://github.com/scottr131/linux.git
```

Now, install the Ceph, Qemu, and Incus stacks onto the build node by running the Ansible playbooks. Ceph won't be used, but this version of QEMU is linked against it, so it needs to be installed.

```bash
cd ~/build-system/ansible
ansible-playbook -i hosts.ini -e "target_hosts=buildhost" ceph/ceph-on-slackware.yaml
ansible-playbook -i hosts.ini -e "target_hosts=buildhost" qemu/qemu-on-slackware.yaml
ansible-playbook -i hosts.ini -e "target_hosts=buildhost" incus/incus-on-slackware.yaml
ansible-playbook -i hosts.ini -e "target_hosts=buildhost" incus/incus-groups.yaml
ansible-playbook -i hosts.ini -e "target_hosts=buildhost" local-config/local-config.yaml
```

Finally, we need to create a local network bridge to allow the VMs to connect to the LAN. Edit `/etc/rc.d/rc.inet1.conf`. In most cases you can just add two lines to create a bridge on eth0.

```bash
# IPv4 config options for eth0:
IPADDRS[0]="10.1.31.18/24"
USE_DHCP[0]=""
# IPv6 config options for eth0:
IP6ADDRS[0]=""
USE_SLAAC[0]=""
USE_DHCP6[0]=""
# Generic options for eth0:
DHCP_HOSTNAME[0]=""

## Add these lines
BRNICS[0]="eth0"
IFNAME[0]="br-lan"
```


At this point, the system needs restarted for the CGROUPS version change to take effect. The incus daemon should come up automatically after restart. Skip the next section on manual installation, as Incus has been installed.


#### Incus on Build Node (Manual Installation)

**These steps are only necessary if Incus was NOT installed via Ansible.** The next step is create a deployment node that will used to network boot and deploy software to the other nodes. The deployment node will be a virtual machine, so we need to get Incus running on the build node. To do this, we need to install the packages from qemu-stack and incus-stack. Since this build of Qemu depends on Ceph, ceph-stack will need installed too.

```bash
# Replace <build number> with your latest successful build number
cd ~/build-system/jenkins/jobs/ceph-stack/builds/<build number>/archive/
sudo installpkg *.txz
cd ~/build-system/jenkins/jobs/qemu-stack/builds/<build number>/archive/
sudo installpkg *.txz
cd ~/build-system/jenkins/jobs/incus-stack/builds/<build number>/archive/
sudo installpkg *.txz
```

Install configuration files

```bash
cd ~
wget https://github.com/scottr131/linux/raw/refs/heads/main/slackware/etc/rc.d/rc.local
wget https://github.com/scottr131/linux/raw/refs/heads/main/slackware/etc/rc.d/rc.incusd

sudo cp rc.local rc.incusd /etc/rc.d/
sudo chmod +x /etc/rc.d/rc.local /etc/rc.d/rc.incusd
```

We also need to configure `incusd`. Create /etc/default/incusd with these contents:

```
# Default options for the incus daemon:
#

INCUSD_OPTS="--group=incus --logfile=/var/log/incusd"
INCUS_UI="/opt/incus/ui"
JAVA_HOME="/opt/java21"
```

Then we need to create the Incus groups and subuid/subgid mappings.

```
sudo groupadd -r -g 345 incus
sudo groupadd -r -g 346 incus-admin
echo "root:1000000:1000000000" | sudo tee -a /etc/subuid /etc/subgid
```

Slackware defaults to cgroups v1. Incus needs cgroups v2. Edit `/etc/default/cgroups`

```
CGROUPS_VERSION=2
```

Finally, we need to create a local network bridge to allow the VMs to connect to the LAN. Edit `/etc/rc.d/rc.inet1.conf`. In most cases you can just add two lines to create a bridge on eth0.

```
# IPv4 config options for eth0:
IPADDRS[0]="10.1.31.18/24"
USE_DHCP[0]=""
# IPv6 config options for eth0:
IP6ADDRS[0]=""
USE_SLAAC[0]=""
USE_DHCP6[0]=""
# Generic options for eth0:
DHCP_HOSTNAME[0]=""

## Add these lines
BRNICS[0]="eth0"
IFNAME[0]="br-lan"
```

Reboot the build node so that the cgroups and networking changes can take effect. The build node should come up with `incusd` running. Continue with the instructions immediately below.

### Configure Incus on Build Node

** Resume here after installing Incus **
Now we need to configure Incus.  

```bash
sudo incus admin init
```

Below is a sample run. Settings may need adjusted per the environment.

```text
Would you like to use clustering? (yes/no) [default=no]:
Do you want to configure a new storage pool? (yes/no) [default=yes]:
Name of the new storage pool [default=default]:
Name of the storage backend to use (ceph, lvm, dir, btrfs) [default=btrfs]: dir
Where should this storage pool store its data? [default=/var/lib/incus/storage-pools/default]:
Would you like to create a new local network bridge? (yes/no) [default=yes]: no
Would you like to use an existing bridge or host interface? (yes/no) [default=no]: yes
Name of the existing bridge or host interface: br-lan
Would you like the server to be available over the network? (yes/no) [default=no]: yes
Address to bind to (not including port) [default=all]:
Port to bind to [default=8443]:
Would you like stale cached images to be updated automatically? (yes/no) [default=yes]:
Would you like a YAML "init" preseed to be printed? (yes/no) [default=no]:
```

Verfiy network connectivity by configuring local user client.

```bash
sudo incus config trust add localhost
# incus will return a token
incus remote add localhost
# Confirm fingerprint and paste token
```

Verify server operation.

```bash
incus remote switch localhost
incus list
# This should return an empty list of instances
```

#### Deployment Node (VM)

#### Preparation

Create a `usb` mountpoint and mount the Slackware files USB flash drive.
```bash
sudo mkdir -p /mnt/usb
sudo mount /dev/sdg1 /mnt/usb
```

Create the VM and import the Slackware installer USB image.

```bash
# Create the VM
incus create --empty deploy --vm -s default -c limits.memory=4GiB -c limits.cpu=2 -d root,size=32GiB
# Import the slackware installer image (not technically an ISO, but it will import this way)
incus storage volume import default /mnt/usb/slackware64-current/usb-and-pxe-installers/usbboot.img slackware-install --type=iso
# Attach the Slackware USB to the deploy VM
incus storage volume attach default slackware-install deploy installer
# Set the deploy VM to boot from the USB installer
incus config device set deploy installer boot.priority=10
```

You will need to connect a remote Incus client or configure the web interface in order to see the VM console. Those are currently beyond the scope of this document.

##### Install OS

Connect the USB flash drive of Slackware files to the VM. Boot the VM and connect to the console. Install Slackware in a manner similar to the build node. This time only install package series a, ap, l, n, tcl, x, xap, and xfce from the `mini-gui` tagfiles. Configure the VM with a hostname of `deploy` and a static IP address appropriate for your LAN. Just as with the build node, you will need to create the cluster account `clusteradm`.

```bash
# These are examples and will need to be modified.
incus config device add deploy usb1 usb busnum=1 devnum=5
incus start deploy --console=vga
```

##### Configure Deployment Node

```
# As root, since there are no other accounts
useradd -d /home/clusteradm -g users -u 1050 -m -s /bin/bash clusteradm
```

In addiition, we need to grant `sudo` access to the `clusteradm` account. The path includes `go` - it is not yet installed, but will be soon. Edit `/etc/sudoers.d/clusteradm` as follows:

```
#Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/go/bin"
clusteradm ALL=(ALL:ALL) ALL
```

Make sure to set a password on the clusteradm account.

```
passwd clusteradm
```

Also, it's a good idea to configure an NTP server in `/etc/ntp.conf`. Shut down the VM, disconnect the virtual Slackware installer USB, leave your real Slackware files USB connected, and boot up the VM into the newly installed OS.

##### Copy Deployment Scripts

Once you've confirmed the VM is working, shut it down. We need to add some files to the real Slackware files USB. Mount the USB on the host system then copy the autoinstall scripts and tagfiles to it. As root on the host system do something like:

```
mount /dev/sdb1 /mnt/hd   # Modify based on your host system
cd /mnt/hd
# Tagfiles are part of my linux repository
git clone https://github.com/scottr131/linux.git
# Scripts location TBD, assume as ~/scripts
mkdir -p /mnt/hd/scripts
cp /home/clusteradm/scripts/* /mnt/hd/scripts/
umount /mnt/hd
```

##### Create Deploy Directory Tree

Restart the `deploy` instance (`incus start deploy`). The USB should be reconnected to the VM. SSH into the VM as clusteradm. Mount the Slackware files USB flash drive to /mnt/hd and prepare the files for network deployment. Network boot files will be stored in `/srv`. Slackware will be stored at `/srv/slackware/slackware64-current`, tagfiles at `/srv/slackware/tagsets`, `/srv/pxe` contains the boot binaries, `/srv/pxe/nodes` contains node-specific configuration files, and `/srv/tftp` contains the boot binaries to be served via TFTP by dnsmasq.

The node-specific config directory is actually `/srv/pxe/nodes`. This document will have a companion repository that contains scripts and config files. The location is yet to be determined. For the moment, assume the Slackware flies USB drive contains a `scripts` directory with deployment related scripts and a `conf` directory that contains various configuration file templates.

As `clusteradm`, create the directory tree and own it. Copy the scripts and tagsets off the USB.

```
mkdir ~/scripts
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb
sudo mkdir -p /srv/pxe/nodes /srv/slackware/tagsets /srv/tftp
sudo chown -R clusteradm /srv/pxe /srv/slackware /srv/tftp
#cp /mnt/hd/scripts/* ~/scripts/
cp -R /mnt/usb/tagfiles/* /srv/slackware/tagsets
```

##### Copy Local Mirror

Now we'll use rsync to copy the Slackware mirror. This same command can be used later to synchronize the Slackware mirror from a USB flash drive.

```
rsync -havP --delete --delete-after  --no-o --no-g --safe-links  --timeout=60  --exclude "EFI/*" --exclude "extra/*" --exclude "pasture/*" --exclude "patches/*"  --exclude "source/*"  --exclude "testing/*" /mnt/usb/slackware64-current /srv/slackware
```

##### Configure Network Boot

Now we need to set up the iPXE files. These instructions don't currently include building iPXE. It should be added to a stack. As an aside, it can built on the build node with:

```
git clone https://github.com/scottr131/slackbuilds.git
cd slackbuilds
make ipxe
```

This should result in an `ipxe` package in `/tmp/packages` - currently `/tmp/packages/ipxe-2.0.0-x86_64-1_SBo.txz`. This can be copied to the deploy node and installed with `sudo installpkg ipxe-2.0.0-x86_64-1_SBo.txz`.

```
cp /usr/share/ipxe/bin-x86_64-efi/*.efi /srv/tftp/
cp /mnt/hd/config/boot.ipxe /srv/pxe/
```

Edit `/srv/pxe/boot.ipxe`. If you followed the paths in this document you usually will just need to change the line that starts with `set srv` to point to the LAN IP address of the `deploy` VM. Additional documentation is in the config file itself.

##### Install build-system (for Caddy and Semaphore UI)

Now we need to install the build-system. This is the easiest way to get a web server on the deploy node and we'll need build-system for Semaphore UI. We won't configure it at this point. As `clusteradm`:

```bash
cd ~
# We can't git clone like build node because we don't have git
wget https://github.com/scottr131/build-system/archive/refs/heads/main.zip
unzip main.zip
mv build-system-main build-system
```

##### Configure Build System

Now, configure the build system. 

```bash
cd build-system
# Download binaries
./build-system.sh download all
# Create directories
./build-system.sh setup dirs
# Set up JDKs
./build-system.sh setup jdk
# Setup the auth system and reverse proxy
# You will be prompted for a username and password
./build-system.sh setup rp
# Setting up the reverse proxy extracts Caddy
```

##### Configure HTTP boot server

Make a local copy of the Caddyfile. We don't have a good place for it, so we'll put in the scripts directory for now.

```bash
cp /mnt/hd/conf/caddy-pxe.conf ~/scripts/
```

Verify `~/scripts/pxe-boot-server.sh` is correct for your system

```bash
#!/bin/bash
sudo  ~/build-system/bin/caddy run --adapter caddyfile --config caddy-pxe.conf
```

##### Configure Proxy DHCP and TFTP via dnsmasq

Verify `~/scripts/pxe-tftp-server.sh` is correct for your system

```bash
#!/bin/bash
sudo /usr/sbin/dnsmasq -C /etc/dnsmasq.d/pxe.conf -d
```

We also need to copy the dnsmasq config. This can probably be combined with the steps that copy caddy-pxe.conf and boot.ipxe. 

```bash
sudo cp /mnt/hd/config/pxe.conf /etc/dnsmasq.d/
```

Edit `/etc/dnsmasq.d/pxe.conf` and make sure the settings are right for your LAN. The key settings are `interface=`,  `dhcp-range=`, and `dhcp-boot=`. dnsmsaq will proxyDHCP with your existing DHCP server and allow network boot (in most cases). 

##### Custom Installer

Now we need to generate the custom Slackware installer image. This is automated with the `build-initrd.sh` script. Additional documentaiton is available inside the script.

```bash
cd ~/scripts
sudo ./build-initrd.sh
# You should see output indicating a successful path of the installer image
# It takes a little bit of time to repack the image
```

##### Configure NFS Exports

Next, we need to set up NFS to serve the Slackware package mirror. Edit `/etc/exports` with the line

```
/srv/slackware/slackware64-current   192.168.1.0/24(ro,sync,no_subtree_check,root_squash)
```

Make sure to replace `192.168.1.0` with your LAN's address.  Enable and start NFS, then reload the exports (just in case).

```
sudo chmod +x /etc/rc.d/rc.rpc /etc/rc.d/rc.nfsd
sudo /etc/rc.d/rc.rpc start
sudo /etc/rc.d/rc.nfsd start
sudo exportfs -ra
```

##### Start Network Boot Server

Set our pxe boot scripts to executable.

```bash
cd ~/scripts
chmod +x ~/scripts/pxe-boot-server.sh ~/scripts/pxe-tftp-server.sh
```

Start the dnsmasq and caddy servers. This is best done in a tmux session.

```bash
# In tmux
~/scripts/pxe-tftp-server.sh
# In another tmux shell
~/scripts/pxe-boot-server.sh
```

##### Node Specific Configuration

Create a configuration file for the first cluster node - a networking node - `nnode1`. Edit `/srv/pxe/nodes/<mac addr>.cfg` where `<mac addr>` is the hypen-separated MAC address of the target node. ** Make sure you have a valid SSH pubkey in this file. This will be your only way into the target node **

```
NODE_ROLE="compute"        # or "storage" �.. picks the OS disk + partition layout
NODE_NAME="provisionn1"
CLUSTERADM_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTEsAAAAIBwdl67NEdcb30yKG6Sp+VfzfrbcTlg771jhVh5WShCz4 clusteradm@build34.example.net"
TIMEZONE="America/New_York"   # default UTC
HWCLOCK="localtime"                 # or localtime; default UTC
#TAG_URL=""
PKG_OUTPUT="--infobox"
SYSTEM_SIZE="64GiB"
ROOT_LV_SIZE="48GiB"
DATA_PART_TYPE="zfs"
TAG_URL="http://192.168.1.100/tagsets/mini-gui"
```

Now it's time to boot the first node. Let's make this nnode1 - the first node of the networking cluster. This is a good place to start because the networking nodes have their primary network interface connected to the existing LAN. While configuring the nodes to network boot, it is also a good time to configure the firmware settings.

Check these settings (terms will vary):

- CSM: Disabled
- Boot: UEFI Only
- Secure Boot: Disabled (Slackware boot chain isn't signed)
- Virtualiation Technology (Hardware Virtualization): Enabled
- VT-d / Vi / I/O Virtualization: Enabled
- Onboard Ethernet: Enabled
- PXE IPv4 Network Stack: Enabled

Boot the node into UEFI network boot. You should see iPXE boot followed by the Linux kernel and eventually the Slackware installer. If the node configuration file is located, the node will display a message indicating that it is ready to install. Press enter to install.

Repeat this process with the other two network nodes. You could go ahead and install software on all 9 nodes now if it is more convenient.

The newly installed nodes should come up and grab an IP address from DHCP. You should be able to SSH into them from `deploy` by their hostnames (which should get registered automatically when the node obtains an IP). 

Back on `deploy` we need to get Ansible and Semaphore running to start deploying software to the nodes.

```
cd ~/build-system

# Get playbooks
wget https://github.com/scottr131/ansible/archive/refs/heads/main.zip
unzip main.zip
mv ansible-main/ ansible/
rm main.zip

./build-system.sh setup semaphore
# You will be prompted for a new username
# and password for Semaphore UI

# Now start the reverse proxy and Semaphore UI
./build-system.sh start semaphore
./build-system.sh start rp
```

Now edit ~/build-system/ansible/hosts.ini and add the network nodes to the provisioning group.

```
[provisionnode]
p-nnode1 ansible_user=clusteradm lan_gateway=10.1.31.1 lan_ip=10.1.31.51/24 cluster_ip=10.168.1.51/24 ovn_ip=192.168.120.51/24 storage_ip=192.168.130.51/24 new_hostname=nnode1 lan_hwaddr=0e:38:9c:57:8e:d2 cluster_hwaddr=d2:00:ed:42:88:72 uplink_hwaddr=c6:b0:13:9b:9d:27
p-nnode2 ansible_user=clusteradm lan_gateway=10.1.31.1 lan_ip=10.1.31.52/24 cluster_ip=10.168.1.52/24 ovn_ip=192.168.120.52/24 storage_ip=192.168.130.52/24 new_hostname=nnode2 lan_hwaddr=6a:52:cb:c8:b7:80 cluster_hwaddr=52:c2:fd:40:54:f3 uplink_hwaddr=62:58:db:73:65:94
p-nnode3 ansible_user=clusteradm lan_gateway=10.1.31.1 lan_ip=10.1.31.53/24 cluster_ip=10.168.1.53/24 ovn_ip=192.168.120.53/24 storage_ip=192.168.130.53/24 new_hostname=nnode3 lan_hwaddr=c6:5c:4c:61:9a:d8 cluster_hwaddr=72:6a:4f:b3:4b:fa uplink_hwaddr=3e:42:8c:d6:4e:02

[all:vars]
cluster_gateway=10.1.31.1
domain="i131.net"
```

Back to the build node. We need to copy the txz packages built earlier onto the deploy node. There is not current an automated way to do this. The process is something like:

```bash
# Replace <build number> with your latest successful build number
cd ~/build-system/jenkins/jobs/qemu-stack/builds/<build number>/archive/
scp *.txz deploy:~/build-system/ansible/slackware/files/
cd ~/build-system/jenkins/jobs/incus-stack/builds/<build number>/archive/
scp *.txz deploy:~/build-system/ansible/slackware/files/
cd ~/build-system/jenkins/jobs/storage-stack/builds/<build number>/archive/
scp *.txz deploy:~/build-system/ansible/slackware/files/
cd ~/build-system/jenkins/jobs/ovn-stack/builds/<build number>/archive/
scp *.txz deploy:~/build-system/ansible/slackware/files/
cd ~/build-system/jenkins/jobs/ceph-stack/builds/<build number>/archive/
scp *.txz deploy:~/build-system/ansible/slackware/files/
cd ~/build-system/jenkins/jobs/mgmt-tools/builds/<build number>/archive/
scp *.txz deploy:~/build-system/ansible/slackware/files/
cd ~/build-system/jenkins/jobs/dev-tools/builds/<build number>/archive/
scp *.txz deploy:~/build-system/ansible/slackware/files/
```

Now that packages are copied to the deploy node, go back to the deploy node and install Ansible - `sudo installpkg ~/build-system/ansible/slackware/files/ansible-2.21.2-x86_64-1_SBo.txz`.

Finally, in a web browser, go to the Semaphore UI instance at `https://semaphore.<your-server>.<domain>`. You will recieve two certificate warnings because of self signed certificates. One is for the Authelia certficiate and one is for the Jenkins certificate. Bypass these errors and you should get an Authelia login page. Login with the reverse proxy account created earlier. Make sure to check "Remember me" if you are on your local LAN.

You will be asked to create a new project in Semaphore. Instead, click the "Restore Project..." link on the left and restore the backup from from the companion repository. This creates Semaphore tasks for the Ansible playbooks.

Test Semaphore with the "Execute Comamnd" task. Set "Target Hosts" to `pronvisionnode` and `pwd` as the command. All hosts should return /home/clusteradm.

Now deploy the networking configuration tasks to the network nodes (currently in the `provisionnode` group)

- Change Hostname
- Deploy Dual NON-BOND Networking Configuration

Since these are currently the only nodes in `provisionnode`, go ahead and deploy the following tasks too:

- Enable Intel IOMMU (or optionally Enable AMD IOMMU if the node is AMD)
- Deploy Ceph (QEMU was compiled with Ceph, so we need Ceph installed)
- Deploy Incus
- Create Incus Groups
- Deploy Local Config
- Deploy ntp config

Now run the "Execute Command" task with `reboot` as the command, `provisionnode` as the target hosts, and set Run as root to Yes. This will reboot the nodes to apply the networking changes and the cgroups version change made by the Incus playbook.

After the nodes reboot, SSH into `nnode1` and initialize Incus.

```
sudo incus admin init
...
Would you like to use clustering? (yes/no) [default=no]: yes
What IP address or DNS name should be used to reach this server? [default=192.168.130.51]: 10.168.1.51
Are you joining an existing cluster? (yes/no) [default=no]:
What member name should be used to identify this server in the cluster? [default=nnode1.cluster.local]: nnode1
Do you want to configure a new local storage pool? (yes/no) [default=yes]:
Name of the storage backend to use (btrfs, dir, lvm) [default=btrfs]: lvm
Create a new LVM pool? (yes/no) [default=yes]:
Would you like to use an existing empty block device (e.g. a disk or partition)? (yes/no) [default=no]: yes
Path to the existing block device: /dev/nvme0n1p3
Do you want to configure a new remote storage pool? (yes/no) [default=no]:
Would you like to use an existing bridge or host interface? (yes/no) [default=no]: yes
Name of the existing bridge or host interface: br-cluster
Would you like stale cached images to be updated automatically? (yes/no) [default=yes]:
Would you like a YAML "init" preseed to be printed? (yes/no) [default=no]:
...

# Create tokens for the other nodes
incus cluster add nnode2
incus cluster add nnode3
```

Repeat the process on `nnode2` and `nnode3`.

```
Would you like to use clustering? (yes/no) [default=no]: yes
What IP address or DNS name should be used to reach this server? [default=192.168.130.53]: 10.168.1.53
Are you joining an existing cluster? (yes/no) [default=no]: yes
Please provide join token:
All existing data is lost when joining a cluster, continue? (yes/no) [default=no] yes
Choose "lvm.thinpool_name" property for storage pool "local":
Choose "lvm.vg_name" property for storage pool "local":
Choose "source" property for storage pool "local": /dev/nvme0n1p3
Would you like a YAML "init" preseed to be printed? (yes/no) [default=no]:
```

Deploy the router instances on the networking cluster. This is currently done by restoring the backups. TODO - document the process of creating the router images.

Remove the internal ethernet port from the trunk on the switch for each of the compute and cluster nodes. The LACP truck isn't supported during network boot. In my case, this also puts the nodes on the LAN vlan - which is currently the VLAN that `deploy` is on.

Deploy all software to the storage and compute nodes. Finally, apply the networking configuration and shut the nodes down. Add the ports back to the trunks and power on the nodes. The nodes should now come up with a bonded interface and on the cluster LAN at their specified IP address (from hosts.ini).

Move the deploy VM from the build node to the networking cluster. Since this is more of a tool VM, we'll keep it off the main compute cluster.

Form the compute cluster. On `cnode1`

```
sudo incus admin init
Would you like to use clustering? (yes/no) [default=no]: yes
What IP address or DNS name should be used to reach this server? [default=10.168.1.41]:
Are you joining an existing cluster? (yes/no) [default=no]:
What member name should be used to identify this server in the cluster? [default=cnode1]:
Do you want to configure a new local storage pool? (yes/no) [default=yes]:
Name of the storage backend to use (btrfs, lvm, dir) [default=btrfs]: lvm
Create a new LVM pool? (yes/no) [default=yes]:
Would you like to use an existing empty block device (e.g. a disk or partition)? (yes/no) [default=no]: yes
Path to the existing block device: /dev/nvme0n1p3
Do you want to configure a new remote storage pool? (yes/no) [default=no]:
Would you like to use an existing bridge or host interface? (yes/no) [default=no]:
Would you like stale cached images to be updated automatically? (yes/no) [default=yes]:
Would you like a YAML "init" preseed to be printed? (yes/no) [default=no]: yes
config:
  core.https_address: 10.168.1.41:8443
networks: []
storage_pools:
  - config:
      source: /dev/nvme0n1p3
    description: ""
    name: local
    driver: lvm
storage_volumes: []
profiles:
  - config: {}
    description: ""
    devices:
      root:
        path: /
        pool: local
        type: disk
    name: default
    project: default
projects: []
certificates: []
cluster_groups: []
cluster:
  server_name: cnode1
  enabled: true
  member_config: []
  cluster_address: ""
  cluster_certificate: ""
  server_address: ""
  cluster_token: ""
  cluster_certificate_path: ""
```

Repeat on cnode2 and cnode3.

```
Would you like to use clustering? (yes/no) [default=no]: yes
What IP address or DNS name should be used to reach this server? [default=192.168.120.43]: 10.168.1.43
Are you joining an existing cluster? (yes/no) [default=no]: yes
Please provide join token: 
...
All existing data is lost when joining a cluster, continue? (yes/no) [default=no] yes
Choose "lvm.thinpool_name" property for storage pool "local":
Choose "lvm.vg_name" property for storage pool "local":
Choose "source" property for storage pool "local": /dev/nvme0n1p3
Would you like a YAML "init" preseed to be printed? (yes/no) [default=no]: yes
config: {}
networks: []
storage_pools: []
storage_volumes: []
profiles: []
projects: []
certificates: []
cluster_groups: []
cluster:
  server_name: cnode3
  enabled: true
  member_config:
    - entity: storage-pool
      name: local
      key: lvm.thinpool_name
      value: ""
      description: '"lvm.thinpool_name" property for storage pool "local"'
    - entity: storage-pool
      name: local
      key: lvm.vg_name
      value: ""
      description: '"lvm.vg_name" property for storage pool "local"'
    - entity: storage-pool
      name: local
      key: source
      value: /dev/nvme0n1p3
      description: '"source" property for storage pool "local"'
  cluster_address: 10.168.1.41:8443
  cluster_certificate: |
    -----BEGIN CERTIFICATE-----
...
    -----END CERTIFICATE-----
  server_address: 10.168.1.43:8443
  cluster_token: ""
  cluster_certificate_path: ""
```
