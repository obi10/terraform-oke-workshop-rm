data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_services" "all" {}

data "oci_core_images" "oracle_linux8" {
  count                    = var.worker_image_id == null ? 1 : 0
  compartment_id           = var.tenancy_ocid
  operating_system         = var.worker_image_os
  operating_system_version = var.worker_image_os_version
  shape                    = var.worker_node_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

data "oci_core_images" "oracle_linux9_bastion" {
  count                    = var.bastion_image_id == null ? 1 : 0
  compartment_id           = var.tenancy_ocid
  operating_system         = var.bastion_image_os
  operating_system_version = var.bastion_image_os_version
  shape                    = var.bastion_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
  state                    = "AVAILABLE"
}

locals {
  compartment_name = lower(var.compartment_name)
  cluster_name     = lower(var.cluster_name)

  all_services = [
    for svc in data.oci_core_services.all.services : svc
    if can(regex("All .* Services In Oracle Services Network", svc.name))
  ]

  all_services_service_id = try(local.all_services[0].id, null)
  all_services_cidr       = try(local.all_services[0].cidr_block, null)
  node_image_id           = coalesce(var.worker_image_id, try(data.oci_core_images.oracle_linux8[0].images[0].id, null))
  bastion_image_id        = coalesce(var.bastion_image_id, try(data.oci_core_images.oracle_linux9_bastion[0].images[0].id, null))
  bastion_user_data       = <<-EOT
    #!/bin/bash
    set -euxo pipefail

    dnf -y upgrade-minimal --security
    dnf -y install oraclelinux-developer-release-el9
    dnf -y install python3 python3-pip curl unzip jq telnet dnf-plugins-core

    # -- Docker ----------------------------------------------------------------
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    usermod -aG docker opc

    bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" \
      -- --accept-all-defaults --install-dir /opt/oci-cli --exec-dir /usr/local/bin

    # -- kubectl ---------------------------------------------------------------
    ARCH="$(uname -m)"
    if [ "$ARCH" = "aarch64" ]; then
      KARCH="arm64"
    else
      KARCH="amd64"
    fi

    KVER="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
    curl -L -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$${KVER}/bin/linux/$${KARCH}/kubectl"
    chmod +x /usr/local/bin/kubectl

    # -- OCI dirs --------------------------------------------------------------
    install -d -m 700 /root/.oci
    install -d -m 700 -o opc -g opc /home/opc/.oci

    # -- Write API private key -------------------------------------------------
    cat <<'PEMEOF' > /home/opc/.oci/oci_api_key.pem
    ${var.private_key_pem}
    PEMEOF
    chmod 600 /home/opc/.oci/oci_api_key.pem
    cp /home/opc/.oci/oci_api_key.pem /root/.oci/oci_api_key.pem
    chmod 600 /root/.oci/oci_api_key.pem

    # -- OCI CLI config with API key auth -------------------------------------
    cat <<'CONFEOF' > /home/opc/.oci/config
    [DEFAULT]
    user=${var.user_ocid}
    fingerprint=${var.fingerprint}
    tenancy=${var.tenancy_ocid}
    region=${var.region}
    key_file=/home/opc/.oci/oci_api_key.pem
    CONFEOF
    chmod 600 /home/opc/.oci/config

    cp /home/opc/.oci/config /root/.oci/config
    sed -i 's|/home/opc/.oci/oci_api_key.pem|/root/.oci/oci_api_key.pem|' /root/.oci/config
    chmod 600 /root/.oci/config
    chown -R opc:opc /home/opc/.oci

    # -- No instance_principal -------------------------------------------------
    printf '# OCI CLI uses config file auth\n' > /etc/profile.d/oci-cli.sh
    chmod 644 /etc/profile.d/oci-cli.sh

    # -- kube dirs -------------------------------------------------------------
    install -d -m 700 /root/.kube
    install -d -m 700 -o opc -g opc /home/opc/.kube

    # -- kubeconfig with retry -------------------------------------------------
    MAX_RETRIES=10
    SLEEP_SECONDS=30

    for i in $(seq 1 $MAX_RETRIES); do
      echo "Intento $i/$MAX_RETRIES: generando kubeconfig..."

      if oci ce cluster create-kubeconfig \
        --cluster-id "${oci_containerengine_cluster.oke.id}" \
        --file /root/.kube/config \
        --region "${var.region}" \
        --token-version 2.0.0 \
        --kube-endpoint PUBLIC_ENDPOINT; then

        echo "kubeconfig generado exitosamente"
        cp /root/.kube/config /home/opc/.kube/config
        chown -R opc:opc /home/opc/.kube
        chmod 600 /root/.kube/config /home/opc/.kube/config
        break
      else
        echo "WARN: intento $i fallo, esperando $${SLEEP_SECONDS}s..." >&2
        sleep $SLEEP_SECONDS
      fi

      if [ "$i" -eq "$MAX_RETRIES" ]; then
        echo "ERROR: no se pudo generar kubeconfig tras $MAX_RETRIES intentos" >&2
      fi
    done
  EOT
}

resource "terraform_data" "bastion_bootstrap" {
  input = sha256(local.bastion_user_data)
}

resource "oci_identity_compartment" "oke" {
  provider = oci.home_region

  compartment_id = var.compartment_ocid
  name           = local.compartment_name
  description    = var.compartment_description
  enable_delete  = false

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_vcn" "oke" {
  compartment_id = oci_identity_compartment.oke.id
  cidr_blocks    = distinct(concat([var.vcn_cidr], var.vcn_additional_cidr_blocks))
  display_name   = "vcn-${local.cluster_name}"
  dns_label      = "okevcn"

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_internet_gateway" "oke" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "igw-${local.cluster_name}"
  enabled        = true

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_nat_gateway" "oke" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "nat-${local.cluster_name}"

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_service_gateway" "oke" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "sgw-${local.cluster_name}"

  services {
    service_id = local.all_services_service_id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_network_security_group" "api_endpoint" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "nsg-api-endpoint-${local.cluster_name}"

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_network_security_group" "workers" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "nsg-workers-${local.cluster_name}"

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_network_security_group" "pods" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "nsg-pods-${local.cluster_name}"

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_network_security_group" "load_balancer" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "nsg-lb-${local.cluster_name}"

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_network_security_group" "bastion" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "nsg-bastion-${local.cluster_name}"

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_route_table" "api_endpoint" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "rt-api-endpoint-${local.cluster_name}"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.oke.id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_route_table" "workers" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "rt-workers-${local.cluster_name}"

  route_rules {
    destination       = local.all_services_cidr
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.oke.id
  }

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.oke.id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_route_table" "pods" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "rt-pods-${local.cluster_name}"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.oke.id
  }

  route_rules {
    destination       = local.all_services_cidr
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.oke.id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_route_table" "load_balancer" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "rt-lb-${local.cluster_name}"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.oke.id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_route_table" "bastion" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "rt-bastion-${local.cluster_name}"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.oke.id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_security_list" "api_endpoint" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "sl-api-endpoint-${local.cluster_name}"

  ingress_security_rules {
    protocol    = "6"
    source      = var.workers_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 6443
      max = 6443
    }
    description = "Allow worker nodes to communicate with the API endpoint over the Kubernetes API port"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.workers_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 12250
      max = 12250
    }
    description = "Allow worker nodes to communicate with the API endpoint over the Kubernetes API and kubelet ports"
  }

  ingress_security_rules {
    protocol    = "1"
    source      = var.workers_subnet_cidr
    source_type = "CIDR_BLOCK"

    icmp_options {
      type = 3
      code = 4
    }
    description = "Allow worker nodes to send ICMP unreachable messages for path MTU discovery and other network diagnostics"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.pods_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.pods_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 12250
      max = 12250
    }
    description = "Allow pods to communicate with the API endpoint over the Kubernetes API and kubelet ports for CNI and kubelet operations"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.bastion_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 6443
      max = 6443
    }
    description = "Allow bastion host to communicate with the API endpoint over the Kubernetes API port for administration and troubleshooting"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"
    description      = "Allow API endpoint to access Oracle Services Network for communicate to OKE's control plane and pulling container images from OCIR"
  }

  egress_security_rules {
    protocol         = "1"
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"

    icmp_options {
      type = 3
      code = 4
    }
    description = "Allow API endpoint to send ICMP unreachable messages for path MTU discovery and other network diagnostics when communicating with Oracle Services Network"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.workers_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 10250
      max = 10250
    }
    description = "Allow API endpoint to communicate with worker nodes over the kubelet port for node management and monitoring"
  }

  egress_security_rules {
    protocol         = "1"
    destination      = var.workers_subnet_cidr
    destination_type = "CIDR_BLOCK"

    icmp_options {
      type = 3
      code = 4
    }
    description = "Allow API endpoint to send ICMP unreachable messages for path MTU discovery and other network diagnostics when communicating with worker nodes"
  }

  egress_security_rules {
    protocol         = "all"
    destination      = var.pods_subnet_cidr
    destination_type = "CIDR_BLOCK"
    description      = "Allow API endpoint to communicate with pods over the pod subnet for CNI and kubelet operations"
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_security_list" "workers" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "sl-workers-${local.cluster_name}"

  ingress_security_rules {
    protocol    = "6"
    source      = var.api_endpoint_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 10250
      max = 10250
    }
    description = "Allow API endpoint to communicate with worker nodes over the kubelet port for node management and monitoring"
  }

  ingress_security_rules {
    protocol    = "1"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"

    icmp_options {
      type = 3
      code = 4
    }
    description = "Allow API endpoint and other sources to send ICMP unreachable messages for path MTU discovery and other network diagnostics"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.bastion_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 22
      max = 22
    }
    description = "Allow bastion host to communicate with worker nodes over SSH for administration and troubleshooting"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.load_balancer_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 30000
      max = 32767
    }
    description = "Allow load balancer to communicate with worker nodes over the NodePort range for Kubernetes services exposed via NodePort"
  }

  ingress_security_rules {
    protocol    = "6"
    source      = var.load_balancer_subnet_cidr
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 10256
      max = 10256
    }
    description = "Allow load balancer to communicate with worker nodes over the Kubernetes API and kubelet port for health checks and other operations"
  }

  egress_security_rules {
    protocol         = "all"
    destination      = var.pods_subnet_cidr
    destination_type = "CIDR_BLOCK"
    description      = "Allow worker nodes to communicate with pods over the pod subnet for CNI and kubelet operations"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"
    description      = "Allow worker nodes to access Oracle Services Network for communicate to OKE's control plane and pulling container images from OCIR"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.api_endpoint_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 6443
      max = 6443
    }
    description = "Allow worker nodes to communicate with the API endpoint over the Kubernetes API port"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.api_endpoint_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 12250
      max = 12250
    }
    description = "Allow worker nodes to communicate with the API endpoint over the Kubernetes API and kubelet ports"
  }

  egress_security_rules {
    protocol         = "1"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"

    icmp_options {
      type = 3
      code = 4
    }
    description = "Allow worker nodes to send ICMP unreachable messages for path MTU discovery and other network diagnostics"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 443
      max = 443
    }
    description = "Allow worker nodes to access external container registries and other services over HTTPS"
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_security_list" "pods" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "sl-pods-${local.cluster_name}"

  ingress_security_rules {
    protocol    = "all"
    source      = var.workers_subnet_cidr
    source_type = "CIDR_BLOCK"
    description = "Allow worker nodes to communicate with pods over the pod subnet for CNI and kubelet operations"
  }

  ingress_security_rules {
    protocol    = "all"
    source      = var.api_endpoint_subnet_cidr
    source_type = "CIDR_BLOCK"
    description = "Allow API endpoint to communicate with pods over the pod subnet for CNI and kubelet operations"
  }

  ingress_security_rules {
    protocol    = "all"
    source      = var.pods_subnet_cidr
    source_type = "CIDR_BLOCK"
    description = "Allow pods to communicate with each other over the pod subnet for CNI and kubelet operations"
  }

  egress_security_rules {
    protocol         = "all"
    destination      = var.pods_subnet_cidr
    destination_type = "CIDR_BLOCK"
    description      = "Allow pods to communicate with each other over the pod subnet for CNI and kubelet operations"
  }

  egress_security_rules {
    protocol         = "1"
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"

    icmp_options {
      type = 3
      code = 4
    }
    description = "Allow pods to send ICMP unreachable messages for path MTU discovery and other network diagnostics"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = local.all_services_cidr
    destination_type = "SERVICE_CIDR_BLOCK"
    description      = "Allow pods to access Oracle Services Network for communicate to OKE's control plane and pulling container images from OCIR"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 443
      max = 443
    }
    description = "Allow pods to access external container registries and other services over HTTPS"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.api_endpoint_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 6443
      max = 6443
    }
    description = "Allow pods to communicate with the API endpoint over the Kubernetes API port for CNI and kubelet operations"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.api_endpoint_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 12250
      max = 12250
    }
    description = "Allow pods to communicate with the API endpoint over the Kubernetes API and kubelet ports for CNI and kubelet operations"
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_security_list" "load_balancer" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "sl-lb-${local.cluster_name}"

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    description = "Allow incoming traffic to load balancer from any source for Kubernetes services exposed via LoadBalancer"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.workers_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 30000
      max = 32767
    }
    description = "Allow load balancer to communicate with worker nodes over the NodePort range for Kubernetes services exposed via NodePort"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.workers_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 10256
      max = 10256
    }
    description = "Allow load balancer to communicate with worker nodes over the Kubernetes API and kubelet port for health checks and other operations"
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_security_list" "bastion" {
  compartment_id = oci_identity_compartment.oke.id
  vcn_id         = oci_core_vcn.oke.id
  display_name   = "sl-bastion-${local.cluster_name}"

  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"

    tcp_options {
      min = 22
      max = 22
    }
    description = "Allow incoming SSH traffic to bastion host from any source for administration and troubleshooting"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.api_endpoint_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 6443
      max = 6443
    }
    description = "Allow bastion host to communicate with the API endpoint over the Kubernetes API port for administration and troubleshooting"
  }

  egress_security_rules {
    protocol         = "6"
    destination      = var.workers_subnet_cidr
    destination_type = "CIDR_BLOCK"

    tcp_options {
      min = 22
      max = 22
    }
    description = "Allow bastion host to communicate with worker nodes over SSH for administration and troubleshooting"
  }

  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    description      = "Allow bastion host to access external resources for administration and troubleshooting"
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_subnet" "api_endpoint" {
  compartment_id             = oci_identity_compartment.oke.id
  vcn_id                     = oci_core_vcn.oke.id
  cidr_block                 = var.api_endpoint_subnet_cidr
  display_name               = "snet-api-endpoint-${local.cluster_name}"
  dns_label                  = "apioke"
  security_list_ids          = [oci_core_security_list.api_endpoint.id]
  route_table_id             = oci_core_route_table.api_endpoint.id
  prohibit_public_ip_on_vnic = false

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_subnet" "workers" {
  compartment_id             = oci_identity_compartment.oke.id
  vcn_id                     = oci_core_vcn.oke.id
  cidr_block                 = var.workers_subnet_cidr
  display_name               = "snet-workers-${local.cluster_name}"
  dns_label                  = "workers"
  security_list_ids          = [oci_core_security_list.workers.id]
  route_table_id             = oci_core_route_table.workers.id
  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_subnet" "pods" {
  compartment_id             = oci_identity_compartment.oke.id
  vcn_id                     = oci_core_vcn.oke.id
  cidr_block                 = var.pods_subnet_cidr
  display_name               = "snet-pods-${local.cluster_name}"
  dns_label                  = "pods"
  security_list_ids          = [oci_core_security_list.pods.id]
  route_table_id             = oci_core_route_table.pods.id
  prohibit_public_ip_on_vnic = true
  prohibit_internet_ingress  = true

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_core_subnet" "load_balancer" {
  compartment_id             = oci_identity_compartment.oke.id
  vcn_id                     = oci_core_vcn.oke.id
  cidr_block                 = var.load_balancer_subnet_cidr
  display_name               = "snet-lb-${local.cluster_name}"
  dns_label                  = "lb${substr(md5(var.load_balancer_subnet_cidr), 0, 6)}"
  security_list_ids          = [oci_core_security_list.load_balancer.id]
  route_table_id             = oci_core_route_table.load_balancer.id
  prohibit_public_ip_on_vnic = false

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
    create_before_destroy = true
  }
}

resource "oci_core_subnet" "bastion" {
  compartment_id             = oci_identity_compartment.oke.id
  vcn_id                     = oci_core_vcn.oke.id
  cidr_block                 = var.bastion_subnet_cidr
  display_name               = "snet-bastion-${local.cluster_name}"
  dns_label                  = "bas${substr(md5(var.bastion_subnet_cidr), 0, 6)}"
  security_list_ids          = [oci_core_security_list.bastion.id]
  route_table_id             = oci_core_route_table.bastion.id
  prohibit_public_ip_on_vnic = false

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
    create_before_destroy = true
  }
}

resource "oci_core_instance" "bastion" {
  compartment_id      = oci_identity_compartment.oke.id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  display_name        = "vm-bastion-${local.cluster_name}"
  shape               = var.bastion_shape

  shape_config {
    ocpus         = var.bastion_ocpus
    memory_in_gbs = var.bastion_memory_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.bastion.id
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.bastion.id]
  }

  source_details {
    source_type             = "IMAGE"
    source_id               = local.bastion_image_id
    boot_volume_size_in_gbs = var.bastion_boot_volume_size_gbs
  }

  metadata = {
    ssh_authorized_keys = var.bastion_ssh_public_key
    user_data           = base64encode(local.bastion_user_data)
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
    replace_triggered_by = [terraform_data.bastion_bootstrap]

    precondition {
      condition     = local.bastion_image_id != null
      error_message = "No se encontro una imagen Oracle Linux 9 compatible. Define var.bastion_image_id."
    }
  }
}

resource "oci_containerengine_cluster" "oke" {
  compartment_id     = oci_identity_compartment.oke.id
  name               = var.cluster_name
  type               = var.cluster_type
  vcn_id             = oci_core_vcn.oke.id
  kubernetes_version = var.kubernetes_version

  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  endpoint_config {
    is_public_ip_enabled = true
    nsg_ids              = [oci_core_network_security_group.api_endpoint.id]
    subnet_id            = oci_core_subnet.api_endpoint.id
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.load_balancer.id]

    kubernetes_network_config {
      services_cidr = var.services_cidr
    }
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  depends_on = [
    oci_core_route_table.api_endpoint,
    oci_core_route_table.workers,
    oci_core_route_table.pods,
    oci_core_route_table.load_balancer,
    oci_core_route_table.bastion
  ]

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }

  timeouts {
    create = "2h"
    update = "2h"
    delete = "2h"
  }
}

resource "oci_containerengine_node_pool" "workers" {
  compartment_id     = oci_identity_compartment.oke.id
  cluster_id         = oci_containerengine_cluster.oke.id
  name               = var.node_pool_name
  kubernetes_version = var.kubernetes_version
  node_shape         = var.worker_node_shape

  node_shape_config {
    ocpus         = var.worker_node_ocpus
    memory_in_gbs = var.worker_node_memory_gbs
  }

  node_config_details {
    size = var.worker_node_count
    nsg_ids = [
      oci_core_network_security_group.workers.id
    ]

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.workers.id
    }

    node_pool_pod_network_option_details {
      cni_type       = "OCI_VCN_IP_NATIVE"
      pod_subnet_ids = [oci_core_subnet.pods.id]
      pod_nsg_ids    = [oci_core_network_security_group.pods.id]
    }
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = local.node_image_id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]

    precondition {
      condition     = local.node_image_id != null
      error_message = "No se encontro una imagen Oracle Linux 8 compatible. Define var.worker_image_id."
    }
  }

  timeouts {
    create = "2h"
    update = "2h"
    delete = "2h"
  }
}

resource "oci_containerengine_node_pool" "apps" {
  compartment_id     = oci_identity_compartment.oke.id
  cluster_id         = oci_containerengine_cluster.oke.id
  name               = var.apps_node_pool_name
  kubernetes_version = var.kubernetes_version
  node_shape         = var.worker_node_shape

  node_shape_config {
    ocpus         = var.worker_node_ocpus
    memory_in_gbs = var.worker_node_memory_gbs
  }

  node_config_details {
    size = var.apps_worker_node_count
    nsg_ids = [
      oci_core_network_security_group.workers.id
    ]

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = oci_core_subnet.workers.id
    }

    node_pool_pod_network_option_details {
      cni_type       = "OCI_VCN_IP_NATIVE"
      pod_subnet_ids = [oci_core_subnet.pods.id]
      pod_nsg_ids    = [oci_core_network_security_group.pods.id]
    }
  }

  node_source_details {
    source_type = "IMAGE"
    image_id    = local.node_image_id
  }

  freeform_tags = var.freeform_tags
  defined_tags  = var.defined_tags

  lifecycle {
    ignore_changes = [
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]

    precondition {
      condition     = local.node_image_id != null
      error_message = "No se encontro una imagen Oracle Linux 8 compatible. Define var.worker_image_id."
    }
  }

  timeouts {
    create = "2h"
    update = "2h"
    delete = "2h"
  }
}
