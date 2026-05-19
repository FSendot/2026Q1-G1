#!/bin/bash
set -euo pipefail

exec > >(tee /var/log/onprem-tx-producer-bootstrap.log | logger -t onprem-tx-producer -s 2>/dev/console) 2>&1

export AWS_DEFAULT_REGION="${region}"

yum install -y python3 python3-pip bind-utils >/dev/null
pip3 install --quiet boto3

install -d -m 0755 /opt/onprem-tx-producer
cat >/opt/onprem-tx-producer/tx_producer.py <<'EOF'
${producer_script}
EOF
chmod 0755 /opt/onprem-tx-producer/tx_producer.py

cat >/etc/systemd/system/onprem-tx-producer.service <<EOF
[Unit]
Description=Continuous on-prem transaction producer for ingestion SQS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=QUEUE_URL=${queue_url}
Environment=AWS_REGION=${region}
Environment=BATCH_SIZE=${batch_size}
Environment=LOOP_INTERVAL_SEC=${loop_interval_sec}
Environment=FRAUD_PCT=${fraud_pct}
ExecStartPre=/bin/bash -c 'for i in $$(seq 1 60); do ip=$$(dig +short sqs.${region}.amazonaws.com | head -n1); if [[ -n "$$ip" ]]; then exit 0; fi; sleep 5; done; echo "SQS private DNS not ready after 5 minutes"; exit 1'
ExecStart=/usr/bin/python3 /opt/onprem-tx-producer/tx_producer.py
Restart=always
RestartSec=10
StandardOutput=append:/var/log/onprem-tx-producer.log
StandardError=append:/var/log/onprem-tx-producer.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable onprem-tx-producer.service
systemctl restart onprem-tx-producer.service
