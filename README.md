# GPUDirect-TCPXO Benchmarks on GKE A3 Mega (H100)

End-to-end guide and benchmark results for **GPUDirect-TCPXO (FasTrak)** on Google Kubernetes Engine using **A3 Mega** VMs with **NVIDIA H100 Mega 80GB** GPUs.

## 🚀 Results at a Glance

### NCCL Communication Benchmarks

| Benchmark | Peak Bus Bandwidth | Speedup |
|-----------|-------------------:|--------:|
| Intra-node NVLink (8 GPUs) | **471.40 GB/s** | baseline |
| Inter-node TCP (16 GPUs) | **3.60 GB/s** | 1x |
| **Inter-node TCPXO (16 GPUs)** | **188.82 GB/s** | **~52x** |

> GPUDirect-TCPXO delivers **188 GB/s** inter-node bandwidth — a **~52x speedup** over standard TCP networking.

### GLM-5.1 (753B MoE) — Multi-Node Inference with GPUDirect-TCPXO GDRDMA

**Config:** 2 nodes × 8 H100 GPUs (16 total)
- **Parallelism:** TP=8 (intra-node via NVLink) + PP=2 (inter-node via TCPXO GDRDMA)
- **Quantization:** fp8 weights + fp8 KV cache (required for 753B on 16 GPUs)
- **Max context:** 202,752 tokens
- **Architecture:** `GlmMoeDsaForCausalLM` (Mixture of Experts with Dense Attention)
- **vLLM engine:** V1 with Ray multi-node orchestration

#### Single-Request Latency

| Output Tokens | Latency (ms) | Decode Speed (tok/s) |
|--------------:|-------------:|---------------------:|
| 50 | 12,121 | 4.1 |
| 100 | 22,040 | 4.5 |
| 200 | 44,370 | **4.5** |

#### Concurrent Throughput

| Concurrency | Output Tokens | Engine Throughput (tok/s) |
|------------:|--------------:|-------------------------:|
| 1 | 100 | 4.5 |
| 4 | 400 | **5.9** |

#### Key Metrics

| Metric | Value |
|--------|------:|
| GPU KV Cache | **858,048 tokens** |
| Max Concurrency (202K context) | **4.23×** |
| Weight Download (HuggingFace) | **694s (~1.5 TB)** |
| Weight Loading (worker → GPU) | **48s** |
| Weight Loading (head → GPU) | **87s** |
| Total Startup Time | **~15 min** |

> **TCPXO plugin-only approach:** vLLM uses its own bundled NCCL 2.27.5 (NOT the host's 2.28.7). Only the TCPXO net plugin (`libnccl-net.so`) and tuner are mounted — no `LD_PRELOAD`, no host NCCL override. The TCPXO shim's v7 API is compatible with NCCL 2.27.5+.

> **Why fp8 quantization is required:** GLM-5.1 has 753B parameters. With TP=8, PP=2 (16 GPUs), each GPU holds ~47B params. In bf16 that's ~94 GB/GPU — exceeding the H100's 79 GiB. fp8 halves this to ~47 GB/GPU, leaving ~32 GB for KV cache. Without quantization, you'd need 3-4 nodes (PP=3 or PP=4).

## 📋 Prerequisites

- Google Cloud project with GPU quota for `a3-megagpu-8g` in your target region
- `gcloud` CLI installed and authenticated
- `kubectl` installed
- `gh` CLI (optional, for repo management)

## 🔧 Step-by-Step Setup

### 1. Set Environment Variables

```bash
export PROJECT_ID="your-gcp-project-id"
export REGION="us-west1"
export ZONE="us-west1-a"
export CLUSTER_NAME="tcpxo-cluster"
export PREFIX="tcpxo"
```

### 2. Create VPC Networks (8 networks with Jumbo MTU)

```bash
for N in $(seq 1 8); do
  gcloud compute networks create ${PREFIX}-net-${N} \
    --subnet-mode=custom \
    --mtu=8244 \
    --project=${PROJECT_ID}

  gcloud compute networks subnets create ${PREFIX}-sub-${N} \
    --network=${PREFIX}-net-${N} \
    --region=${REGION} \
    --range="192.168.${N}.0/24" \
    --project=${PROJECT_ID}

  gcloud compute firewall-rules create ${PREFIX}-internal-${N} \
    --network=${PREFIX}-net-${N} \
    --action=ALLOW \
    --rules=tcp:0-65535,udp:0-65535,icmp \
    --source-ranges="192.168.${N}.0/24" \
    --project=${PROJECT_ID}
done
```

### 3. Create GKE Cluster

```bash
gcloud beta container clusters create ${CLUSTER_NAME} \
  --enable-dataplane-v2 \
  --enable-ip-alias \
  --location=${REGION} \
  --enable-multi-networking \
  --cluster-version=1.33.10-gke.1067000 \
  --no-enable-autoupgrade \
  --project=${PROJECT_ID}
```

> **Note:** `beta` is required for multi-networking support.

### 4. Create Network & GKENetworkParamSet Resources

```bash
for i in $(seq 1 8); do
cat <<EOF | kubectl apply -f -
apiVersion: networking.gke.io/v1
kind: Network
metadata:
  name: vpc${i}
spec:
  parametersRef:
    group: networking.gke.io
    kind: GKENetworkParamSet
    name: vpc${i}
  type: Device
---
apiVersion: networking.gke.io/v1
kind: GKENetworkParamSet
metadata:
  name: vpc${i}
spec:
  vpc: ${PREFIX}-net-${i}
  vpcSubnet: ${PREFIX}-sub-${i}
  deviceMode: NetDevice
EOF
done
```

### 5. Create GPU Node Pool

```bash
gcloud beta container node-pools create gpu-pool \
  --location=${REGION} \
  --cluster=${CLUSTER_NAME} \
  --project=${PROJECT_ID} \
  --node-locations=${ZONE} \
  --accelerator=type=nvidia-h100-mega-80gb,count=8,gpu-driver-version=LATEST \
  --machine-type=a3-megagpu-8g \
  --num-nodes=2 \
  --additional-node-network network=${PREFIX}-net-1,subnetwork=${PREFIX}-sub-1 \
  --additional-node-network network=${PREFIX}-net-2,subnetwork=${PREFIX}-sub-2 \
  --additional-node-network network=${PREFIX}-net-3,subnetwork=${PREFIX}-sub-3 \
  --additional-node-network network=${PREFIX}-net-4,subnetwork=${PREFIX}-sub-4 \
  --additional-node-network network=${PREFIX}-net-5,subnetwork=${PREFIX}-sub-5 \
  --additional-node-network network=${PREFIX}-net-6,subnetwork=${PREFIX}-sub-6 \
  --additional-node-network network=${PREFIX}-net-7,subnetwork=${PREFIX}-sub-7 \
  --additional-node-network network=${PREFIX}-net-8,subnetwork=${PREFIX}-sub-8 \
  --enable-gvnic \
  --no-enable-autoupgrade \
  --scopes "https://www.googleapis.com/auth/cloud-platform"
```

### 6. Install NCCL TCPXO Plugin

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-tcpxo-installer.yaml

# Verify (wait ~2 minutes)
kubectl get pods -n kube-system -l name=nccl-tcpxo-installer
```

### 7. Deploy NRI Device Injector

```bash
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nri_device_injector/nri-device-injector.yaml

# Verify
kubectl get pods -n kube-system | grep device-injector
```

### 8. Run NCCL Benchmarks (Optional)

```bash
# Deploy NCCL test workload
kubectl apply -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-test-latest.yaml

# Wait for pods (both should show 2/2 Running)
kubectl get pods -l tcpxo=daemon

# Set up SSH between pods
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  '/scripts/init_ssh.sh host1.nccl-host-1.default.svc.cluster.local host2.nccl-host-2.default.svc.cluster.local'

# Generate hostfiles
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  'cd /scripts && /scripts/gen_hostfiles.sh host1.nccl-host-1.default.svc.cluster.local host2.nccl-host-2.default.svc.cluster.local'

# Configure SSH
for pod in nccl-test-host-1 nccl-test-host-2; do
  kubectl exec $pod -c nccl-test -- bash -c '
    echo "StrictHostKeyChecking no" >> /root/.ssh/config
    echo "UserKnownHostsFile /dev/null" >> /root/.ssh/config
    chmod 600 /root/.ssh/config'
done

# Add hostname resolution
HOST1_IP=$(kubectl get pod nccl-test-host-1 -o jsonpath='{.status.podIP}')
HOST2_IP=$(kubectl get pod nccl-test-host-2 -o jsonpath='{.status.podIP}')
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  "echo '$HOST2_IP host2' >> /etc/hosts; echo '$HOST1_IP host1' >> /etc/hosts"
kubectl exec nccl-test-host-2 -c nccl-test -- bash -c \
  "echo '$HOST1_IP host1' >> /etc/hosts; echo '$HOST2_IP host2' >> /etc/hosts"

# Run all_gather benchmark
kubectl exec nccl-test-host-1 -c nccl-test -- bash -c \
  'BENCHMARK=all_gather_perf NHOSTS=2 NCCL_LIB_DIR="/usr/local/nvidia/lib64" LD_LIBRARY_PATH="/usr/local/nvidia/lib64" /scripts/demo-run-nccl-test-tcpxo-via-mpi.sh'
```

### 9. Deploy GLM-5.1 (753B MoE) with TCPXO

```bash
# Deploy the GLM-5.1 multi-node inference workload
kubectl apply -f vllm-inference/vllm-glm-tcpxo.yaml

# Wait for pods (both should show 2/2 Running — vllm + tcpxo-daemon sidecar)
kubectl get pods -l tcpxo=daemon

# Monitor model download progress (~1.5 TB, ~12 min)
kubectl exec vllm-head -c vllm -- bash -c 'du -sh /root/.cache/huggingface/'

# Check for TCPXO GDRDMA confirmation in logs
kubectl logs vllm-head -c vllm 2>&1 | grep -i "GDRDMA\|shim_v7\|Application startup"

# Wait for "Application startup complete" (~15 min total)
kubectl logs vllm-head -c vllm --tail=5

# Port-forward for API access
kubectl port-forward pod/vllm-head 8000:8000

# Test inference
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"zai-org/GLM-5.1","messages":[{"role":"user","content":"Explain quantum computing."}],"max_tokens":100}'
```

#### Expected Log Confirmations

You should see these in `kubectl logs vllm-head -c vllm`:

```
# TCPXO plugin loaded on all GPUs
NCCL INFO NET/Plugin: Loaded net plugin uninitialized_shim_v7 (v7) [repeated 15x across cluster]
NCCL INFO Successfully loaded external plugin libnccl-net.so
NCCL INFO Initialized NET plugin uninitialized_shim_v7

# GDRDMA channels established between nodes
NCCL INFO Channel 00/0 : 1[1] -> 0[1] [receive] via NET/uninitialized_shim_v7/1/GDRDMA
NCCL INFO Channel 00/0 : 0[1] -> 1[1] [send] via NET/uninitialized_shim_v7/1/GDRDMA

# Model loaded and serving
Loading weights took 48.02 seconds  (worker)
Loading weights took 86.91 seconds  (head)
GPU KV cache size: 858,048 tokens
Maximum concurrency for 202,752 tokens per request: 4.23x
Application startup complete.
```

## 🧹 Cleanup

```bash
# Delete GLM workload
kubectl delete -f vllm-inference/vllm-glm-tcpxo.yaml

# Delete NCCL test pods (if deployed)
kubectl delete pod nccl-test-host-1 nccl-test-host-2 2>/dev/null
kubectl delete svc nccl-host-1 nccl-host-2 2>/dev/null

# Delete DaemonSets
kubectl delete -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/nri_device_injector/nri-device-injector.yaml
kubectl delete -f https://raw.githubusercontent.com/GoogleCloudPlatform/container-engine-accelerators/master/gpudirect-tcpxo/nccl-tcpxo-installer.yaml

# Delete cluster
gcloud container clusters delete ${CLUSTER_NAME} --location=${REGION} --project=${PROJECT_ID} --quiet

# Delete networking
for N in $(seq 1 8); do
  gcloud compute networks subnets delete ${PREFIX}-sub-${N} --region=${REGION} --project=${PROJECT_ID} --quiet
  gcloud compute firewall-rules delete ${PREFIX}-internal-${N} --project=${PROJECT_ID} --quiet
  gcloud compute networks delete ${PREFIX}-net-${N} --project=${PROJECT_ID} --quiet
done
```

## 📁 Repository Contents

| File | Description |
|------|-------------|
| `README.md` | This setup guide with benchmark results |
| `docs/benchmark-report.md` | Detailed NCCL benchmark report with architecture deep-dive |
| `vllm-inference/vllm-glm-tcpxo.yaml` | GLM-5.1 753B MoE multi-node deployment (TP=8, PP=2, fp8) |

## 🔗 References

- [GCP: Maximize GPU network bandwidth in Standard mode clusters](https://cloud.google.com/kubernetes-engine/docs/how-to/gpu-bandwidth-gpudirect-tcpx)
- [GoogleCloudPlatform/container-engine-accelerators (GitHub)](https://github.com/GoogleCloudPlatform/container-engine-accelerators/tree/master/gpudirect-tcpxo)
- [NVIDIA NCCL Documentation](https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/)
- [GLM-5.1 on HuggingFace](https://huggingface.co/zai-org/GLM-5.1)

## 📊 Software Versions

| Component | Version |
|-----------|---------|
| GKE | 1.33.10-gke.1067000 |
| NCCL (host) | 2.28.7 |
| NCCL (vLLM bundled) | 2.27.5 (via PyTorch) |
| NCCL TCPXO Installer | v1.0.15 |
| FasTrak Network Plugin | v1.0.8 |
| RxDM (tcpgpudmarxd) | v1.0.21 |
| GPU | NVIDIA H100 Mega 80GB HBM3 |
| Machine Type | a3-megagpu-8g |
| vLLM | 0.19.0 (V1 engine) |
| Model | GLM-5.1 (753B MoE) |
