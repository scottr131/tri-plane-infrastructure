resource "incus_instance" "osd1" {
  name = "osd1"
  type = "virtual-machine"
  provider = incus.cluster_storage
  remote = "storage"
  target = "snode2"

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
    name = "eth0"
    type = "nic"
    properties = {
      nictype        = "bridged"
      parent        = "br-cluster"
    }
  }

  device {
    name = "eth1"
    type = "nic"
    properties = {
      nictype        = "bridged"
      parent        = "br-storage"
    }
  }


}
