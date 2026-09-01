resource "incus_instance" "osd0" {
  name = "osd0"
  type = "virtual-machine"
  provider = incus.cluster_storage
  remote = "storage"
  target = "snode1"

  config = {
    "security.secureboot" = false
    "limits.cpu"           = "4"
    "limits.memory"        = "8GiB"
  }

  device {
    name = "root"
    type = "disk"
    properties = {
      pool = "local"
      path = "/"
      size = "48GiB"
    }
  }

  device {
    name = "sata"
    type = "pci"
    properties = {
      address = "0000:00:17.0"
    }
  }
  
  device {
    name = "eth0"
    type = "nic"
    properties = {
      nictype       = "bridged"
      parent        = "br-cluster"
      hwaddr        = "10:66:6a:af:ac:a5"
    }
  }

  device {
    name = "eth1"
    type = "nic"
    properties = {
      nictype       = "bridged"
      parent        = "br-storage"
    }
  }


}
