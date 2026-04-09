# OKE Terraform - Documentacion de Arquitectura

Este entorno (`terraform-oke-workshop-rm`) despliega un cluster OKE con CNI nativo (`OCI_VCN_IP_NATIVE`) y todos los componentes de red necesarios en un solo compartimiento.

## 0. Uso rapido del repositorio

Este repositorio esta preparado para Oracle Resource Manager (RM). RM administra el state y autocompleta `tenancy_ocid`, `compartment_ocid` y `region` en la interfaz del stack.

Este repositorio esta pensado para ser publico y reutilizable por multiples asistentes del workshop. No debe subirse archivos con credenciales ni artefactos locales.

### Crear el stack en RM

Sube la carpeta del proyecto a RM. El archivo `schema.yaml` organiza la UI del stack y oculta las variables autocompletadas por RM.

### Variables que debes ingresar manualmente

- `home_region`: home region del tenancy OCI. Se usa para crear el compartment del workshop.
- `user_ocid`: OCID del usuario cuya API key se configurara dentro de la bastion.
- `fingerprint`: fingerprint de la API key registrada para ese usuario.
- `private_key_pem`: contenido PEM completo de la API key privada que se copiara a la bastion.
- `bastion_ssh_public_key`: llave publica SSH que se inyectara en la VM bastion para acceder por SSH.

RM autocompleta estas variables:

- `tenancy_ocid`
- `compartment_ocid`
- `region`

El resto de variables del template ya viene con valores de referencia para el workshop y solo deben cambiarse si quieres modificar nombres, CIDRs o sizing.

Nota importante: El aprovisionamiento de los servicios se tarda entre 25 a 30 min. Luego, se debe esperar unos 7min mas para que la vm bastion instale y configure oci cli, kubectl.

## 1. Componentes principales creados

- Compartimiento dedicado para OKE, creado en `home region` debajo del `compartment_ocid` seleccionado en el stack.
- VCN y gateways:
  - VCN
  - Internet Gateway
  - NAT Gateway
  - Service Gateway
- Subredes:
  - API endpoint (publica)
  - Workers (privada)
  - Pods compartida para todos los node pools (privada)
  - Load Balancer (publica)
  - Bastion (publica)
- Seguridad de red por capa:
  - Security Lists por subnet
  - Route Tables por subnet
  - NSGs dedicados por rol
- OKE:
  - Cluster `ENHANCED_CLUSTER`
  - CNI nativo OCI
  - Node Pool #1 (sistema/default)
  - Node Pool #2 (apps) usando la misma subnet de pods
- Bastion:
  - VM publica `vm-bastion-<cluster>`
  - Imagen Oracle Linux 9
  - Shape, OCPUs, memoria y boot volume configurables por variables
  - `user_data` de bootstrap para dejar herramientas y acceso a OKE listos

## 2. Topologia de red (CIDRs)

- VCN: `100.0.0.0/16` (adicional: `10.0.0.0/16`)
- API endpoint subnet: `100.0.0.0/29`
- Workers subnet: `100.0.1.0/24`
- Pods subnet compartida: `100.0.32.0/19`
- Load Balancer subnet: `100.0.2.0/24`
- Bastion subnet: `100.0.3.0/24`

## 3. Node pools y relacion con subredes

- Node Pool #1 (`workers`):
  - Nodos en `snet-workers-<cluster>`
  - Pods en `snet-pods-<cluster>`
  - Pod NSG: `nsg-pods-<cluster>`

- Node Pool #2 (`apps`):
  - Nodos en `snet-workers-<cluster>` (misma subnet de workers del pool #1)
  - Pods en `snet-pods-<cluster>` (misma subnet de pods del pool #1)
  - Pod NSG: `nsg-pods-<cluster>`

## 4. Route Tables (resumen)

- `rt-api-endpoint-<cluster>`:
  - `0.0.0.0/0` -> Internet Gateway

- `rt-workers-<cluster>`:
  - `All <region> Services` -> Service Gateway
  - `0.0.0.0/0` -> NAT Gateway

- `rt-pods-<cluster>`:
  - `0.0.0.0/0` -> NAT Gateway
  - `All <region> Services` -> Service Gateway

- `rt-lb-<cluster>`:
  - `0.0.0.0/0` -> Internet Gateway

- `rt-bastion-<cluster>`:
  - `0.0.0.0/0` -> Internet Gateway

## 5. Security Lists (resumen por subnet)

### API endpoint (`sl-api-endpoint-<cluster>`)
- Ingress:
  - Desde workers: TCP `6443`, `12250`, ICMP `3,4`
  - Desde pods compartidos: TCP `6443`, `12250`
  - Desde bastion: TCP `6443`
- Egress:
  - Hacia `All <region> Services`: TCP, ICMP `3,4`
  - Hacia workers: TCP `10250`, ICMP `3,4`
  - Hacia pods compartidos: ALL/ALL

### Workers (`sl-workers-<cluster>`)
- Ingress:
  - Desde API: TCP `10250`
  - Desde bastion: TCP `22`
  - Desde LB subnet: TCP `30000-32767`, `10256`
  - ICMP `3,4`
- Egress:
  - Hacia pods compartidos: ALL/ALL
  - Hacia API: TCP `6443`, `12250`
  - Hacia OCI services: TCP
  - Hacia internet: TCP `443`, ICMP `3,4`

### Pods compartidos (`sl-pods-<cluster>`)
- Ingress:
  - Desde workers: ALL/ALL
  - Desde API: ALL/ALL
  - Desde mismo CIDR pods: ALL/ALL
- Egress:
  - Hacia mismo CIDR pods: ALL/ALL
  - Hacia OCI services: TCP, ICMP `3,4`
  - Hacia internet: TCP `443`
  - Hacia API: TCP `6443`, `12250`

### Load Balancer (`sl-lb-<cluster>`)
- Ingress:
  - Desde internet: TCP (listeners)
- Egress:
  - Hacia workers: TCP `30000-32767`, `10256`

### Bastion (`sl-bastion-<cluster>`)
- Egress:
  - Hacia API: TCP `6443`
  - Hacia workers: TCP `22`

## 6. NSGs (resumen)

- `nsg-api-endpoint-<cluster>`: creado sin reglas.
- `nsg-workers-<cluster>`: creado sin reglas.
- `nsg-pods-<cluster>`: creado sin reglas.
- `nsg-lb-<cluster>`: creado sin reglas.
- `nsg-bastion-<cluster>`: creado sin reglas.

## 7. Nomenclatura aplicada

- Route Tables: `rt-<rol>-<cluster>`
- Security Lists: `sl-<rol>-<cluster>`
- NSGs: `nsg-<rol>-<cluster>`
- Subnets: `snet-<rol>-<cluster>`

## 8. VM Bastion y bootstrap (`user_data`)

Ademas del cluster OKE, el entorno despliega una VM bastion en la subnet publica `snet-bastion-<cluster>` con IP publica y NSG `nsg-bastion-<cluster>`.

La instancia se crea con:

- `ssh_authorized_keys = var.bastion_ssh_public_key`
- `user_data = base64encode(local.bastion_user_data)`
- Reemplazo automatico si cambia el contenido del bootstrap (`terraform_data.bastion_bootstrap`)

El `user_data` definido en `main.tf` realiza este bootstrap inicial:

- Ejecuta `dnf -y upgrade-minimal --security` en lugar de un `dnf update` global
- Instala los paquetes base necesarios: `python3`, `pip`, `curl`, `unzip`, `jq`, `telnet` y `dnf-plugins-core`
- Instala Docker Engine, habilita el servicio con `systemctl enable --now docker` y agrega `opc` al grupo `docker`
- Instala OCI CLI en `/opt/oci-cli` y publica el ejecutable en `/usr/local/bin`
- Descarga e instala `kubectl` segun la arquitectura de la VM
- Crea `/root/.oci`, `/home/opc/.oci`, `/root/.kube` y `/home/opc/.kube`
- Copia la API private key (`var.private_key_pem`) hacia `/home/opc/.oci/oci_api_key.pem` y `/root/.oci/oci_api_key.pem`
- Genera el archivo `~/.oci/config` para `opc` y `root` usando autenticacion por API key
- Genera el `kubeconfig` con `oci ce cluster create-kubeconfig` contra el `PUBLIC_ENDPOINT`
- Reintenta la generacion del `kubeconfig` hasta `10` veces con espera de `30` segundos entre intentos

Resultado operativo: al terminar el provisionamiento, la bastion queda preparada para usar `oci` y `kubectl` tanto con el usuario `opc` como con `root`, apuntando al cluster OKE desplegado por el mismo stack.

## 9. Archivos del entorno

- `.gitignore`: evita subir archivos sensibles o locales al repositorio remoto.
- `provider.tf`: provider OCI simplificado para RM, con alias para `home region`.
- `variables.tf`: variables del entorno.
- `terraform.tfvars.example`: ejemplo de valores para las variables manuales.
- `schema.yaml`: definicion de UI para Resource Manager.
- `main.tf`: recursos de red, OKE, node pools y VM bastion.
- `outputs.tf`: salidas del entorno.

## 10. Nota operativa importante

OCI no permite actualizar en caliente el `cidr_block` de una subnet existente.
Si cambias CIDR de una subnet ya creada, Terraform debe reemplazarla (destroy/create), no actualizarla in-place.
