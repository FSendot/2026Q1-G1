#!/bin/bash
# Wait until the on-prem Route 53 PHZ resolves SQS to the VPCE private IPs.
set -euo pipefail

region="${AWS_REGION:-us-east-1}"
host="sqs.${region}.amazonaws.com"

for _ in $(seq 1 60); do
  ip="$(dig +short "$host" | head -n1)"
  if [[ -n "$ip" ]]; then
    echo "SQS DNS ${host} resolved to ${ip}"
    exit 0
  fi
  sleep 5
done

echo "SQS private DNS not ready after 5 minutes (${host})" >&2
exit 1
