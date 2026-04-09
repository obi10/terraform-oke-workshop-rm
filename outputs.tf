output "oke_compartment_id" {
  description = "OCID del compartment jrpalomino"
  value       = oci_identity_compartment.oke.id
}

output "oke_vcn_id" {
  description = "OCID de la VCN del cluster"
  value       = oci_core_vcn.oke.id
}

output "oke_cluster_id" {
  description = "OCID del cluster OKE"
  value       = oci_containerengine_cluster.oke.id
}

output "oke_cluster_kubernetes_version" {
  description = "Version Kubernetes del cluster"
  value       = oci_containerengine_cluster.oke.kubernetes_version
}

output "oke_node_pool_id" {
  description = "OCID del node pool"
  value       = oci_containerengine_node_pool.workers.id
}

output "oke_api_endpoint_subnet_id" {
  description = "OCID de subnet publica para API"
  value       = oci_core_subnet.api_endpoint.id
}

output "oke_workers_subnet_id" {
  description = "OCID de subnet privada para workers"
  value       = oci_core_subnet.workers.id
}

output "oke_pods_subnet_id" {
  description = "OCID de subnet privada compartida para pods"
  value       = oci_core_subnet.pods.id
}

output "oke_load_balancer_subnet_id" {
  description = "OCID de subnet publica para load balancer"
  value       = oci_core_subnet.load_balancer.id
}

output "oke_bastion_subnet_id" {
  description = "OCID de subnet publica para bastion"
  value       = oci_core_subnet.bastion.id
}

output "oke_bastion_instance_id" {
  description = "OCID de la VM bastion"
  value       = oci_core_instance.bastion.id
}
