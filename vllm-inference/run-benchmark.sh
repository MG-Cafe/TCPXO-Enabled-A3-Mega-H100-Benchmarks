#!/bin/bash
# vLLM Inference Benchmark on A3 Mega H100
# Measures throughput and latency for text generation
set -e

MODEL="NousResearch/Meta-Llama-3-8B"
VLLM_POD="vllm-inference"
API_URL="http://localhost:8000"

echo "============================================"
echo "vLLM Inference Benchmark on A3 Mega (H100)"
echo "Model: $MODEL"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "============================================"

# Warmup
echo ""
echo "--- Warmup (3 requests) ---"
for i in 1 2 3; do
  kubectl exec $VLLM_POD -- curl -s $API_URL/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Hello world\",\"max_tokens\":10,\"temperature\":0}" > /dev/null 2>&1
done
echo "Warmup complete."

# Benchmark 1: Single request latency (varying output lengths)
echo ""
echo "=== Benchmark 1: Single Request Latency ==="
echo "prompt_tokens | max_tokens | latency_ms | tokens_per_sec"
echo "---------------------------------------------------"

for MAX_TOKENS in 32 64 128 256 512; do
  START=$(date +%s%N)
  RESULT=$(kubectl exec $VLLM_POD -- curl -s $API_URL/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Write a detailed essay about the history of artificial intelligence, covering its origins, key milestones, and future directions.\",\"max_tokens\":$MAX_TOKENS,\"temperature\":0.7}")
  END=$(date +%s%N)
  
  LATENCY_MS=$(( (END - START) / 1000000 ))
  COMPLETION_TOKENS=$(echo $RESULT | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null || echo "0")
  
  if [ "$COMPLETION_TOKENS" -gt 0 ] && [ "$LATENCY_MS" -gt 0 ]; then
    TPS=$(python3 -c "print(f'{$COMPLETION_TOKENS / ($LATENCY_MS / 1000):.1f}')")
  else
    TPS="N/A"
  fi
  
  echo "          20  |       $MAX_TOKENS | $LATENCY_MS | $TPS"
done

# Benchmark 2: Concurrent requests throughput
echo ""
echo "=== Benchmark 2: Concurrent Request Throughput ==="
echo "concurrency | total_requests | total_time_ms | req_per_sec | avg_latency_ms"
echo "------------------------------------------------------------------------"

for CONCURRENCY in 1 4 8 16; do
  TOTAL_REQS=$((CONCURRENCY * 4))
  START=$(date +%s%N)
  
  for i in $(seq 1 $TOTAL_REQS); do
    kubectl exec $VLLM_POD -- curl -s $API_URL/v1/completions \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"prompt\":\"Explain quantum computing in simple terms.\",\"max_tokens\":64,\"temperature\":0.7}" > /dev/null 2>&1 &
    
    # Limit concurrent requests
    if (( i % CONCURRENCY == 0 )); then
      wait
    fi
  done
  wait
  
  END=$(date +%s%N)
  TOTAL_MS=$(( (END - START) / 1000000 ))
  RPS=$(python3 -c "print(f'{$TOTAL_REQS / ($TOTAL_MS / 1000):.2f}')")
  AVG_LAT=$(python3 -c "print(f'{$TOTAL_MS / $TOTAL_REQS:.0f}')")
  
  echo "         $CONCURRENCY  |           $TOTAL_REQS | $TOTAL_MS | $RPS | $AVG_LAT"
done

# Benchmark 3: Time to First Token (TTFT) estimation
echo ""
echo "=== Benchmark 3: Time to First Token (streaming) ==="
for PROMPT_LEN in "short" "long"; do
  if [ "$PROMPT_LEN" = "short" ]; then
    PROMPT="Hello"
  else
    PROMPT="Write a comprehensive analysis of the economic impacts of climate change on global agriculture, including effects on crop yields, water resources, and food security across different regions of the world."
  fi
  
  START=$(date +%s%N)
  kubectl exec $VLLM_POD -- curl -s $API_URL/v1/completions \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"$PROMPT\",\"max_tokens\":1,\"temperature\":0}" > /dev/null 2>&1
  END=$(date +%s%N)
  TTFT_MS=$(( (END - START) / 1000000 ))
  echo "Prompt ($PROMPT_LEN): TTFT = ${TTFT_MS}ms"
done

echo ""
echo "============================================"
echo "Benchmark complete!"
echo "============================================"
