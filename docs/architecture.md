# Cluster Architecture

## Overview

This document describes a tri-plane infrastructure platform that
provides storage, networking, virtualization, and container hosting.
Since this will be visualized as three stacked planes, it will be
referred to as the tri-plane infrastructure stack -- or "the stack."

The purpose of the stack is to be a sandbox for exploring
virtualization, DevOps, and IaaC using mostly open-source software.
Virtual machines and containers can run on the stack in independent
projects with access to shared storage and software defined networking.

The stack consists of 9 commodity PCs with at least 16GB or RAM, a
single gigabit ethernet port and USB 3.0, or dual gigabit ethernet
ports. The PCs will be clustered in groups of three (each cluster is a
plane of the stack). The three PCs in a plane should be identical to
each other. PCs can vary across planes as the needs of each plane is
different. One plane will provide the actual compute services while the
other planes will provide storage and networking support.

The nodes run Slackware Linux. This is a point-in-time capture from
Slackware-current and is periodically updated. On top of the OS, the
nodes run Incus for VM and container management. The nodes of each plane
are joined together into an Incus cluster. This allows the nodes in each
plane to be managed as a single logical unit. To provide networking
services, the compute nodes run OVN (Open Virtual Networking). The
compute nodes are on an isolated network. They connect to the outside
world via OpenWrt instances running on the networking plane.

## Planes

### Networking Plane

The networking plane serves as the path into and out of the
infrastructure stack. The networking plane sits on both the customer LAN
and the internal "cluster LAN" of the infrastructure stack. The nodes in
the networking plane have local LVM storage only, as instances should be
small (and probably redundant). In the standard configuration, the
networking plane runs two OpenWrt instances -- one a VM and one a
container. The instances are configured via VRRP to provide a redundant
connection between the customer LAN and cluster LAN.

### Compute Plane

The compute plane is the workhorse of the infrastructure stack. This
plane is composed of the main Incus cluster that runs the customer
workload. These nodes have 32GB of RAM and 500GB of additional SATA SSD
storage. The nodes also form a LINSTOR cluster, providing shared storage
with very fast read speeds and write speeds at nearly 2x network line
rate (via bonded links).

### Storage Plane

The storage plane provides high capacity medium speed shared storage for
the compute cluster. These nodes form another Incus cluster, this one
running Ceph. Each node has a 1TB SATA SDD that is attached to a Ceph
OSD instance. The storage plane nodes themselves provide MON, MGR, and
MDS services.

## Hardware

The infrastructure stack is built as much as possible off commodity
hardware. This is intentional since the main point of the stack is to
learn configuration of the software and hardware rather than pure
performance.

The nodes are mostly identical small-form-factor office PCs. It is
important that these nodes support USB 3.0 to provide enough bandwidth
for an additional network adapter. The nodes are configured with CSM and
secure boot disabled (Slackware's boot chain is not signed), as well as
virtualization, VFIO, and UEFI enabled.

### Nodes

#### Compute

The compute nodes in the test setup have an Intel Core i5-7500T
processor and 32GB of DDR4 RAM. This provides 4 cores of raw compute per
node with no hyperthreading. Each compute node has an additional USB 3.0
gigabit ethernet adapter that is bonded via LACP with the onboard
ethernet adapter. The node's primary storage is a 256GB NVMe. This is
split with 64GB being allocated to the node's own operating system and
the remaining 174GB allocated to a node-local LVM pool. In addition,
each node has a 500GB SATA SSD. These SATA SSDs form a ZFS-backed
LINSTOR pool shared between the nodes. Each node is a satellite, and one
node is a controller.

#### Storage

The storage nodes in the test setup have an Intel Core i5-7500T
processor and 16GB of DDR4 RAM. This provides 4 cores per node with no
hyperthreading. Each storage node has an additional USB 3.0 gigabit
ethernet adapter that is bonded via LACP with the onboard ethernet
adapter. The node's primary storage is a 256GB NVMe. This is split with
64GB being allocated to the node's own operating system and the
remaining 174GB allocated to a node-local LVM pool. In addition, each
node has a 1TB SATA SSD. The SATA controller on each node is passed
through to an OSD instance to become part of the Ceph pool. 8GB of RAM
is allocated to the OSD and 8GB is reserved for the node itself. No
other services, except additional storage services or monitoring, should
run on this cluster.

#### Networking

The storage nodes in the test setup have an Intel Core i5-7500T
processor and 16GB of DDR4 RAM. This provides 4 cores per node with no
hyperthreading. Each storage node has an additional USB 3.0 gigabit
ethernet adapter. Unlike the nodes in other planes, this adapter is not
bonded with the internal ethernet adapter. In the current configuration,
the internal ethernet adapter connects to the customer LAN and the USB
ethernet adapter connects to cluster LAN, although there is no reason
this couldn't be reversed. The node's primary storage is a 256GB NVMe.
This is split with 64GB being allocated to the node's own operating
system and the remaining 174GB allocated to a node-local LVM pool. Only
networking (routing, proxy, switching) or monitoring services should run
on these nodes.

### Networking

#### Switch

This infrastructure stack does require a managed gigabit ethernet
switch. The switch needs to support LACP trunks, preferably with Layer
3 + Layer 4 load balancing for maximum performance. This switch is used
strictly for the infrastructure stack. An LACP trunk of up to 4 members
connects to the customer LAN.

##### VLAN Configuration

The following VLANs should be configured on the swtich.

| VLAN ID     | Description           | IP Network       |
| ----------- | --------------------- | ---------------- |
| 1 (Default) | Customer LAN          | (varies)         |
| 100         | Cluster LAN           | 10.168.1.0/24    |
| 112         | Customer VLAN for VMs | (varies)         |
| 120         | OVN Overlay Traffic   | 192.168.120.0/24 |
| 125         | OVN Uplink            | 192.168.125.0/24 |
| 130         | Storage               | 192.168.130.0/24 |

##### Port Configuration

The switch ports should be configured as trunk members and connected to the nodes as outlined in the table below.

| Port | Trunk | Device              | Device Port       |
| ---- | ----- | ------------------- | ----------------- |
| 1    | 1     | cnode1              | Internal Ethernet |
| 2    | 1     | cnode1              | USB Ethernet      |
| 3    | 2     | cnode2              | Internal Ethernet |
| 4    | 2     | cnode2              | USB Ethernet      |
| 5    | 3     | cnode3              | Internal Ethernet |
| 6    | 3     | cnode3              | USB Ethernet      |
| 7    | 4     | snode1              | Internal Ethernet |
| 8    | 4     | snode1              | USB Ethernet      |
| 9    | 5     | snode2              | Internal Ethernet |
| 10   | 5     | snode2              | USB Ethernet      |
| 11   | 6     | snode3              | Internal Ethernet |
| 12   | 6     | snode3              | USB Ethernet      |
| 13   |       | nnnode1             | Internal Ethernet |
| 14   |       | nnnode1             | USB Ethernet      |
| 15   |       | nnnode2             | Internal Ethernet |
| 16   |       | nnnode2             | USB Ethernet      |
| 17   |       | nnnode3             | Internal Ethernet |
| 18   |       | nnnode3             | USB Ethernet      |
| 19   | 7     | Customer LAN        | Customer Switch   |
| 20   | 7     | Customer LAN        | Customer Switch   |
| 21   | 7     | Customer LAN        | Customer Switch   |
| 22   | 7     | Customer LAN        | Customer Switch   |
| 23   |       |                     |                   |
| 24   |       | Customer LAN Backup | Customer Switch   |

#### Port to VLAN Mapping

| Port    | 1   | 100 | 112 | 120 | 125 | 130 |
| ------- | --- | --- | --- | --- | --- | --- |
| 1*      |     | U   |     |     |     |     |
| 2*      |     | U   |     |     |     |     |
| 3*      |     | U   |     |     |     |     |
| 4*      |     | U   |     |     |     |     |
| 5*      |     | U   |     |     |     |     |
| 6*      |     | U   |     |     |     |     |
| 7*      |     | U   |     |     |     |     |
| 8*      |     | U   |     |     |     |     |
| 9*      |     | U   |     |     |     |     |
| 10*     |     | U   |     |     |     |     |
| 11*     |     | U   |     |     |     |     |
| 12*     |     | U   |     |     |     |     |
| 13      | U   |     |     |     |     |     |
| 14      | T   | T   |     |     |     |     |
| 15      | U   |     |     |     |     |     |
| 16      | T   |     | T   |     |     |     |
| 17      | U   |     |     |     |     |     |
| 18      | T   | T   |     |     |     |     |
| 19*     |     |     |     |     |     |     |
| 20*     |     |     |     |     |     |     |
| 21*     |     |     |     |     |     |     |
| 22*     |     |     |     |     |     |     |
| 23      |     |     | T   |     |     |     |
| 24      |     |     |     |     |     |     |
| TRUNK 1 |     |     | T   | T   | T   | T   |
| TRUNK 2 |     |     | T   | T   | T   | T   |
| TRUNK 3 |     |     | T   |     |     |     |
| TRUNK 4 |     |     | T   |     |     |     |
| TRUNK 5 |     |     |     |     |     |     |
| TRUNK 6 |     |     |     |     |     |     |
| TRUNK 7 |     |     |     |     |     |     |

### Operating System

All hardware nodes in the infrastructure stack run Slackware Linux --
specifically a point-in-time capture of slackware64-current. Much of the
software to run the infrastructure stack is not provided with Slackware,
so it is compiled from scratch using the "build system."

### Build System

The build system is used to compile software for the infrastructure
stack.

https://github.com/scottr131/build-system

#### Jeknins

Jenkins is currently used as the primary build pipeline. It is installed
via the build-system script.

### Instance Management

#### Incus Stack

#### QEMU Stack

### Networking

#### Open vSwitch

#### OVN

#### OpenWrt

#### FRR

### Storage

#### Storage Stack

#### Linstor Stack

### Operations

#### Ansible

#### Semaphore UI

#### OpenTofu

### Monitoring

#### Beszel

#### Grafana

#### Prometheus
