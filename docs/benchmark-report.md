# GPUDirect-TCPXO Benchmarking Guide on GKE with A3 Mega (H100)

## Overview

This guide documents the end-to-end setup and benchmarking of GPUDirect-TCPXO (FasTrak) on Google Kubernetes Engine (GKE) using A3 Mega VMs with NVIDIA H100 Mega 80GB GPUs. It covers infrastructure setup, NCCL benchmarking (intra-node and multi-node with and without TCPXO), and detailed configuration steps.

**Reference:** [GCP Documentation - Maximize GPU network bandwidth in Standard mode clusters](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx)

### Architecture
- **Cluster**: GKE regional cluster in `us-west1` with multi-networking and Dataplane V2
- **GPU Nodes**: 2x A3 Mega (`a3-megagpu-8g`) with 8x NVIDIA H100 Mega 80GB GPUs each
- **Networking**: 8 additional VPC networks for GPUDirect-TCPXO traffic (1 per GPU NIC)
- **NCCL Plugin**: `nccl-plugin-gpudirecttcpx-dev:v1.0.15` (FasTrak architecture, NCCL 2.28.7)
- **RxDM**: `tcpgpudmarxd-dev:v1.0.21` — Receive Data Mover (runs as sidecar in workload pods)

---

## Benchmark Results Summary

| Benchmark | Config | Peak Bus BW | Avg Bus BW |
|-----------|--------|------------:|----------:|
| Intra-node (NVLink) | 8 GPUs, all_reduce | **471.40 GB/s** | — |
| Multi-node TCP baseline | 16 GPUs (2×8), all_reduce | **3.74 GB/s** | — |
| **Multi-node TCPXO** | **16 GPUs (2×8), all_gather** | **188.82 GB/s** | **53.27 GB/s** |

**TCPXO Speedup over TCP: ~52x** (188.82 vs 3.50 GB/s at large message sizes)

---

## Infrastructure Setup

### Step 1: Create VPC Networks and Subnets

```bash
# Create 8 VPC networks with Jumbo frames (MTU 8244 required for TCPXO)
for i in $(seq 1 8); do
  gcloud compute networks create tcpxo-net-$i \
    --subnet-mode=custom \
    --mtu=8244 \
    --project=${PROJECT_ID}
done

# Create subnets
for i in $(seq 1 8); do
  gcloud compute networks subnets create tcpxo-sub-$i \
    --network=tcpxo-net-$i --region=us-west1 --range="192.168.$i.0/24" --project=${PROJECT_ID}
done

# Create firewall rules (allow all TCP/UDP/ICMP traffic within subnets)
for i in $(seq 1 8); do
  gcloud compute firewall-rules create tcpxo-internal-$i \
    --network=tcpxo-net-$i \
    --action=ALLOW \
    --rules=tcp:0-65535,udp:0-65535,icmp \
    --source-ranges="192.168.$i.0/24" \
    --project=${PROJECT_ID}
done
```

### Step 2: Create GKE Cluster

```bash
gcloud beta container clusters create tcpxo-cluster \
  --enable-dataplane-v2 \
  --enable-ip-alias \
  --location=us-west1 \
  --enable-multi-networking \
  --cluster-version=1.33.10-gke.1067000 \
  --no-enable-autoupgrade \
  --project=${PROJECT_ID}
```

> **Note:** The `beta` prefix is required for multi-networking support.

### Step 3: Create Network and GKENetworkParamSet Resources

```bash
for i in $(seq 1 8); do
cat <<EOF | kubectl apply -f -
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc$i
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc$i
  type: Device
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc$i
spec:
  vpc: tcpxo-net-$i
  vpcSubnet: tcpxo-sub-$i
  deviceMode: NetDevice
EOF
done
```

### Step 4: Create GPU Node Pool

```bash
gcloud beta container node-pools create gpu-pool \
  --location=us-west1 \
  --cluster=tcpxo-cluster \
  --project=${PROJECT_ID} \
  --node-locations=us-west1-a \
  --accelerator=type=nvidia-h100-mega-80gb,count=8,gpu-driver-version=LATEST \
  --machine-type=a3-megagpu-8g \
  --num-nodes=2 \
  --spot \
  --additional-node-network network=tcpxo-net-1,subnetwork=tcpxo-sub-1 \
  --additional-node-network network=tcpxo-net-2,subnetwork=tcpxo-sub-2 \
  --additional-node-network network=tcpxo-net-3,subnetwork=tcpxo-sub-3 \
  --additional-node-network network=tcpxo-net-4,subnetwork=tcpxo-sub-4 \
  --additional-node-network network=tcpxo-net-5,subnetwork=tcpxo-sub-5 \
  --additional-node-network network=tcpxo-net-6,subnetwork=tcpxo-sub-6 \
  --additional-node-network network=tcpxo-net-7,subnetwork=tcpxo-sub-7 \
  --additional-node-network network=tcpxo-net-8,subnetwork=tcpxo-sub-8 \
  --enable-gvnic \
  --no-enable-autoupgrade \
  --scopes "https://www.googleapis.com/auth/cloud-platform"
```

### Step 5: Install NCCL TCPXO Plugin (Official DaemonSet)

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-tcpxo-installer.yaml
```

This official DaemonSet (v1.0.15):
- Has **pre-installation initContainer** that runs `modprobe import-helper` and creates `/dev/aperture_devices` for LLCM
- Installs NCCL 2.28.7 + FasTrak libraries to `/home/kubernetes/bin/nvidia/lib64`
- GKE auto-mounts this to `/usr/local/nvidia/lib64` in GPU containers
- Uses `hostPID: true` for kernel module access

### Step 6: Deploy NRI Device Injector

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nri_device_injector/nri-device-injector.yaml
```

This DaemonSet enables GPU device injection into sidecar containers via Pod annotations.

### Step 7: Deploy NCCL Test Workload

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-test-latest.yaml
```

**Key architecture: RxDM runs as a SIDECAR container (`tcpxo-daemon`)** inside each workload pod, NOT as a separate DaemonSet. Critical annotations inject GPU devices into the sidecar:

```yaml
annotations:
  devices.gke.io/container.tcpxo-daemon: |+
    - path: /dev/nvidia0
    - path: /dev/nvidia1
    # ... all 8 GPUs
    - path: /dev/nvidiactl
    - path: /dev/nvidia-uvm
    - path: /dev/dmabuf_import_helper
```

### Step 8: Run the NCCL Test

```bash
# Set up SSH between pods
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  '/scripts/init_ssh.sh host1.nccl-host-1.default.svc.cluster.local host2.nccl-host-2.default.svc.cluster.local'

# Generate hostfiles
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  'cd /scripts && /scripts/gen_hostfiles.sh host1.nccl-host-1.default.svc.cluster.local host2.nccl-host-2.default.svc.cluster.local'

# Fix SSH strict host checking (if needed)
for pod in nccl-test-host-1 nccl-test-host-2; do
  kubectl exec $pod -c nccl-test -- bash -c '
    echo "StrictHostKeyChecking no" >> /root/.ssh/config
    echo "UserKnownHostsFile /dev/null" >> /root/.ssh/config
    chmod 600 /root/.ssh/config'
done

# Add /etc/hosts entries
HOST1_IP=$(kubectl get pod nccl-test-host-1 -o jsonpath='{.status.podIP}')
HOST2_IP=$(kubectl get pod nccl-test-host-2 -o jsonpath='{.status.podIP}')
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  "echo '$HOST2_IP host2' >> /etc/hosts; echo '$HOST1_IP host1' >> /etc/hosts"
kubectl exec nccl-test-host-2 -c nccl-test -- bash -c \
  "echo '$HOST1_IP host1' >> /etc/hosts; echo '$HOST2_IP host2' >> /etc/hosts"

# Run the all_gather benchmark
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  'BENCHMARK=all_gather_perf NHOSTS=2 NCCL_LIB_DIR="/usr/local/nvidia/lib64" LD_LIBRARY_PATH="/usr/local/nvidia/lib64" /scripts/demo-run-nccl-test-tcpxo-via-mpi.sh'
```

---

## Detailed Benchmark Results

### Test 1: Intra-Node NCCL All-Reduce (8x H100 Mega, NVLink/NVSwitch)

**Configuration:** Single A3 Mega node, 8 GPUs, `all_reduce_perf -b 8 -e 2G -f 2 -g 8 -n 20 -w 5`

| Size | Algorithm BW (GB/s) | Bus BW (GB/s) | Time (μs) |
|------|--------------------:|---------------:|----------:|
| 64KB | 1.86 | 3.25 | 35.25 |
| 1MB | 26.84 | 46.96 | 39.07 |
| 16MB | 132.62 | 232.08 | 126.51 |
| 128MB | 226.63 | 396.60 | 592.23 |
| 512MB | 248.17 | 434.30 | 2163.30 |
| 1GB | 266.43 | 466.26 | 4030.04 |
| **2GB** | **269.37** | **471.40** | **7972.23** |

**Peak Bus Bandwidth:** 471.40 GB/s — near-theoretical NVLink/NVSwitch bandwidth

### Test 2: Multi-Node NCCL All-Reduce (TCP/Socket Baseline — NO TCPXO)

**Configuration:** 2 A3 Mega nodes, 16 GPUs, PyTorch `torchrun`, standard TCP/Socket over eth0

| Size | Time (ms) | Algorithm BW (GB/s) | Bus BW (GB/s) |
|------|----------:|--------------------:|---------------:|
| 64KB | 0.388 | 0.67 | 1.27 |
| 1MB | 2.501 | 1.68 | 3.14 |
| 16MB | 34.982 | 1.92 | 3.60 |
| 128MB | 283.337 | 1.89 | 3.55 |
| 512MB | 1150.186 | 1.87 | 3.50 |
| **1GB** | **2301.214** | **1.87** | **3.50** |

**Peak Bus Bandwidth (TCP baseline):** 3.74 GB/s — bottlenecked by single eth0 NIC

### Test 3: Multi-Node NCCL All-Gather (WITH GPUDirect-TCPXO) ⚡

**Configuration:** 2 A3 Mega nodes, 16 GPUs (8 per node), `all_gather_perf -b 8 -e 8G -f 2 -g 1 -w 5 --iters 20`
**Transport:** GPUDirect-TCPXO FasTrak v1.0.8 with 8 NICs, tcpxo-daemon sidecar, NCCL 2.28.7

| Size | Time (μs) | Algorithm BW (GB/s) | Bus BW (GB/s) |
|------|----------:|--------------------:|---------------:|
| 64KB | 110.00 | 0.60 | 0.56 |
| 512KB | 141.74 | 3.70 | 3.47 |
| 1MB | 145.37 | 7.21 | 6.76 |
| 4MB | 156.10 | 26.87 | 25.19 |
| 16MB | 215.98 | 77.68 | 72.83 |
| 64MB | 449.45 | 149.31 | 139.98 |
| 128MB | 796.94 | 168.42 | 157.89 |
| 256MB | 1504.90 | 178.37 | 167.23 |
| 512MB | 2905.13 | 184.80 | 173.25 |
| 1GB | 5496.77 | 195.34 | 183.13 |
| 2GB | 10846.0 | 198.00 | 185.62 |
| 4GB | 21444.5 | 200.28 | 187.76 |
| **8GB** | **42649.6** | **201.41** | **188.82** |

**Average Bus Bandwidth:** 53.27 GB/s (across all sizes including tiny ones)

### Performance Comparison

| Metric | Intra-node (NVLink) | Inter-node TCP | **Inter-node TCPXO** | Speedup |
|--------|--------------------:|---------------:|---------------------:|--------:|
| Peak Bus BW | 471.40 GB/s | 3.74 GB/s | **188.82 GB/s** | **~50x** |
| 1GB Bus BW | 466.26 GB/s | 3.50 GB/s | **183.13 GB/s** | **~52x** |
| 128MB Bus BW | 396.60 GB/s | 3.55 GB/s | **157.89 GB/s** | **~44x** |
| 16MB Bus BW | 232.08 GB/s | 3.60 GB/s | **72.83 GB/s** | **~20x** |

**Key findings:**
- **Note:** TCPXO test uses `all_gather` (the official benchmark) while TCP baseline used `all_reduce`. Bus bandwidth normalizes for collective type, making comparison valid.
- **GPUDirect-TCPXO delivers ~188 GB/s** inter-node bus bandwidth at large sizes — a **52x improvement** over standard TCP
- At 8GB, the **algorithm bandwidth reaches 201 GB/s** (total across 8 GPUDirect NICs)
- TCPXO achieves **~40% of intra-node NVLink bandwidth** for inter-node communication
- Speedup is most dramatic at large message sizes; small messages are latency-bound

---

## TCPXO Architecture Deep-Dive

### Component Stack

```
┌─────────────────────────────────────────┐
│            Workload Pod                 │
│  ┌────────────────┐  ┌───────────────┐ │
│  │   nccl-test    │  │  tcpxo-daemon │ │
│  │ (GPU workload) │  │    (RxDM)     │ │
│  │                │  │  sidecar      │ │
│  │  NCCL 2.28.7   │  │ v1.0.21      │ │
│  │  FasTrak v1.0.8│  │              │ │
│  └───┬──────┬─────┘  └──────┬───────┘ │
│      │ GPU  │ NIC           │ GPU+NIC  │
│      │access│access         │ access   │
│      │      │               │(via NRI) │
├──────┴──────┴───────────────┴──────────┤
│           Node (A3 Mega)               │
│  8x H100 GPUs + 8x GPUDirect NICs     │
│  /dev/aperture_devices (LLCM)          │
│  NCCL libs at /usr/local/nvidia/lib64  │
└────────────────────────────────────────┘
```

### Required Components

1. **NCCL TCPXO Installer** (DaemonSet, `kube-system`)
   - Image: `nccl-plugin-gpudirecttcpx-dev:v1.0.15`
   - Pre-installs kernel module (`import-helper`), creates `/dev/aperture_devices`
   - Copies NCCL + FasTrak libs to `/home/kubernetes/bin/nvidia/lib64`

2. **NRI Device Injector** (DaemonSet, `kube-system`)
   - Injects GPU devices into non-GPU containers via pod annotations
   - Required for tcpxo-daemon sidecar to access GPU devices

3. **tcpxo-daemon Sidecar** (in each workload pod)
   - Image: `tcpgpudmarxd-dev:v1.0.21`
   - Command: `/fts/entrypoint_rxdm_container.sh --num_hops=2 --num_nics=8`
   - Requires: `NET_ADMIN`, `NET_BIND_SERVICE` capabilities
   - Must have GPU devices injected via NRI annotations

4. **Workload Container** (in each workload pod)
   - Env: `NCCL_FASTRAK_LLCM_DEVICE_DIRECTORY=/dev/aperture_devices`
   - Env: `LD_LIBRARY_PATH=/usr/local/nvidia/lib64`
   - Volume: `/dev/aperture_devices` from hostPath

---

## Infrastructure Details

| Component | Details |
|-----------|---------|
| GKE Cluster | `tcpxo-cluster` in `us-west1` |
| Cluster Version | `1.33.10-gke.1067000` |
| GPU Node Type | `a3-megagpu-8g` |
| GPU Model | NVIDIA H100 Mega 80GB HBM3 |
| GPUs per Node | 8 |
| CPU per Node | 208 vCPUs |
| RAM per Node | ~1.84 TB |
| Interconnect (intra-node) | NVLink/NVSwitch (471 GB/s peak) |
| Interconnect (inter-node, TCPXO) | GPUDirect-TCPXO FasTrak (188 GB/s peak) |
| Interconnect (inter-node, TCP) | TCP/Socket over eth0 (3.7 GB/s) |
| NCCL Plugin Version | `v1.0.15` (installer) / `v1.0.8` (FasTrak network plugin) |
| NCCL Library | 2.28.7 (version code 22807) |
| RxDM Version | `v1.0.21` (tcpgpudmarxd-dev) |

## Cleanup

```bash
# Delete test workload
kubectl delete pod nccl-test-host-1 nccl-test-host-2
kubectl delete svc nccl-host-1 nccl-host-2

# Delete DaemonSets
kubectl delete -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nri_device_injector/nri-device-injector.yaml
kubectl delete -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-tcpxo-installer.yaml

# Delete the cluster
gcloud container clusters delete tcpxo-cluster --location=us-west1 --project=${PROJECT_ID} --quiet

# Delete VPC subnets, firewall rules, and networks
for i in $(seq 1 8); do
  gcloud compute networks subnets delete tcpxo-sub-$i --region=us-west1 --project=${PROJECT_ID} --quiet
  gcloud compute firewall-rules delete tcpxo-internal-$i --project=${PROJECT_ID} --quiet
  gcloud compute networks delete tcpxo-net-$i --project=${PROJECT_ID} --quiet
done
```
