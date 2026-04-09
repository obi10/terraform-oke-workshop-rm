variable "tenancy_ocid" {
  description = "OCID del tenancy"
  type        = string
}

variable "compartment_ocid" {
  description = "OCID del compartment seleccionado en Resource Manager; el compartment hijo del workshop se crea debajo de este"
  type        = string
}

variable "user_ocid" {
  description = "OCID del usuario para el bootstrap de la bastion"
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint de la API key usada en el bootstrap de la bastion"
  type        = string
}

variable "private_key_pem" {
  description = "Contenido PEM de la private key usada en el bootstrap de la bastion"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "Region OCI"
  type        = string
}

variable "home_region" {
  description = "Home region del tenancy"
  type        = string
}

variable "compartment_name" {
  description = "Nombre del compartment de OKE"
  type        = string
  default     = "jrpalomino"
}

variable "compartment_description" {
  description = "Descripcion del compartment de OKE"
  type        = string
  default     = "Compartment para OKE clusterOKE"
}

variable "cluster_name" {
  description = "Nombre del cluster OKE"
  type        = string
  default     = "clusteroke"
}

variable "cluster_type" {
  description = "Tipo de cluster OKE (ENHANCED_CLUSTER o BASIC_CLUSTER)"
  type        = string
  default     = "ENHANCED_CLUSTER"
}

variable "kubernetes_version" {
  description = "Version de Kubernetes del cluster"
  type        = string
  default     = "v1.34.2"
}

variable "vcn_cidr" {
  description = "CIDR principal de la VCN"
  type        = string
  default     = "100.0.0.0/16"
}

variable "vcn_additional_cidr_blocks" {
  description = "CIDRs adicionales para la VCN"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "api_endpoint_subnet_cidr" {
  description = "CIDR de subnet API endpoint"
  type        = string
  default     = "100.0.0.0/29"
}

variable "workers_subnet_cidr" {
  description = "CIDR de subnet workers"
  type        = string
  default     = "100.0.1.0/24"
}

variable "pods_subnet_cidr" {
  description = "CIDR de subnet pods"
  type        = string
  default     = "100.0.32.0/19"
}

variable "load_balancer_subnet_cidr" {
  description = "CIDR de subnet load balancer"
  type        = string
  default     = "100.0.2.0/24"
}

variable "bastion_subnet_cidr" {
  description = "CIDR de subnet bastion"
  type        = string
  default     = "100.0.3.0/24"
}

variable "bastion_shape" {
  description = "Shape de la VM bastion"
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "bastion_ocpus" {
  description = "OCPUs de la VM bastion"
  type        = number
  default     = 1
}

variable "bastion_memory_gbs" {
  description = "Memoria de la VM bastion en GB"
  type        = number
  default     = 16
}

variable "bastion_boot_volume_size_gbs" {
  description = "Tamano del boot volume de la VM bastion en GB"
  type        = number
  default     = 128
}

variable "bastion_image_os" {
  description = "Sistema operativo de la VM bastion"
  type        = string
  default     = "Oracle Linux"
}

variable "bastion_image_os_version" {
  description = "Version de SO para la VM bastion"
  type        = string
  default     = "9"
}

variable "bastion_image_id" {
  description = "OCID de imagen para la VM bastion (opcional)"
  type        = string
  default     = null
}

variable "bastion_ssh_public_key" {
  description = "Llave publica SSH para la VM bastion"
  type        = string
}

variable "services_cidr" {
  description = "CIDR de servicios Kubernetes"
  type        = string
  default     = "10.96.0.0/16"
}

variable "node_pool_name" {
  description = "Nombre del node pool"
  type        = string
  default     = "np-clusteroke"
}

variable "worker_node_count" {
  description = "Numero de worker nodes"
  type        = number
  default     = 1
}

variable "apps_node_pool_name" {
  description = "Nombre del segundo node pool"
  type        = string
  default     = "np-apps"
}

variable "apps_worker_node_count" {
  description = "Cantidad de nodos en el segundo node pool"
  type        = number
  default     = 2
}

variable "worker_node_shape" {
  description = "Shape del worker node"
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "worker_node_ocpus" {
  description = "OCPUs del worker node"
  type        = number
  default     = 1
}

variable "worker_node_memory_gbs" {
  description = "Memoria en GB del worker node"
  type        = number
  default     = 8
}

variable "worker_image_os" {
  description = "Sistema operativo para imagen"
  type        = string
  default     = "Oracle Linux"
}

variable "worker_image_os_version" {
  description = "Version del sistema operativo"
  type        = string
  default     = "8"
}

variable "worker_image_id" {
  description = "OCID de imagen para workers (opcional)"
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Freeform tags"
  type        = map(string)
  default = {
    project = "oke"
    env     = "workshop"
  }
}

variable "defined_tags" {
  description = "Defined tags"
  type        = map(string)
  default     = {}
}
