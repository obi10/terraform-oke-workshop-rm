terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "= 8.3.0"
    }
  }
}
provider "oci" {
  region = var.region
}

# Provider alias para home region (Identity, creacion de compartments)
provider "oci" {
  alias  = "home_region"
  region = var.home_region
}
