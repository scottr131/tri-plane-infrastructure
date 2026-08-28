# provider.tf
terraform {
  required_providers {
    incus = {
      source  = "lxc/incus"
      version = "~> 1.0"
    }
  }
}

provider "incus" {
  # Talks to the local Incus daemon over the Unix socket by default —
  # no address/remote block needed for a single-host setup.
  generate_client_certificates = true
  accept_remote_certificate    = true
}

provider "incus" {
  alias = "cluster_storage"
  remote {
    name 	= "storage"
  }
}
