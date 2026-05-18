#!/usr/bin/env python3
"""
Send test transactions through the on-prem EC2 via SSM.

The EC2 lives in the 192.168.0.0/16 VPC, so its SQS requests pass the
CIDR restriction on the queue policy. AWS credentials come from LabInstanceProfile.

Usage:
    python3 scripts/send_test_transactions.py [options]
    make send-test-tx
    make send-test-tx TX_COUNT=20 FRAUD_PCT=30
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import textwrap
import time

import boto3


def get_instance_id(stack_name: str, region: str) -> str:
    cf = boto3.client("cloudformation", region_name=region)
    resp = cf.describe_stacks(StackName=stack_name)
    for o in resp["Stacks"][0].get("Outputs", []):
        if o["OutputKey"] == "VpnGatewayInstanceId":
            return o["OutputValue"]
    raise RuntimeError(f"VpnGatewayInstanceId not found in stack '{stack_name}'")


def get_queue_url(region: str) -> str:
    result = subprocess.run(
        ["terraform", "output", "-raw", "queue_url"],
        capture_output=True,
        text=True,
    )
    url = result.stdout.strip()
    if result.returncode != 0 or not url:
        raise RuntimeError("Could not read queue_url from terraform output — run 'terraform init' first")
    return url


def build_ec2_script(queue_url: str, region: str, count: int, fraud_pct: int) -> str:
    # Pure bash + AWS CLI — no external Python packages needed on the EC2.
    #
    # Fraud pattern: account-drain (amount == old balance, dest is fresh, cross-country,
    # new device/identity). The features blob provides the card/addr/velocity signals
    # the IEEE-CIS model actually uses so the ML engine can produce a high fraud score.
    #
    # Normal pattern: habitual low-value purchase, same country/destination, stable device.
    normal_features = (
        '{"card1":1245,"card2":135,"card3":163,"card5":224,'
        '"addr1":228,"addr2":57,"dist1":0,"dist2":0,'
        '"m1":1,"m2":1,"m3":1,"m5":1,"m6":1,"m7":1,"m8":1,"m9":1,'
        '"c1":1.4,"c2":1.0,"c4":0.2,"c7":1.2,"c10":0.9,"c14":0.3,'
        '"d1":8.5,"d2":0.8,"d3":1.0,"d4":0.9,"d5":0.5,'
        '"v1":0.15,"v20":0.18,"v61":0.12,"v81":0.20,"v101":0.18,'
        '"v130":0.15,"v181":0.14,"v201":0.22,"v241":0.16,"v280":0.18,'
        '"v307":0.15,"v320":0.18,'
        '"id_01":-2.5,"id_02":110,"id_05":3.2,"id_11":2.1,'
        '"id_17":0.8,"id_23":0.4,"id_30":1.0,"id_33":15.0,"id_38":0.9,'
        '"prior_5_transaction_count":3.0,"prior_10_transaction_count":5.0,'
        '"prior_5_amount_sum":750.0,"prior_5_amount_mean":150.0,"prior_5_amount_std":35.0,'
        '"prior_10_amount_sum":1550.0,"prior_10_amount_mean":155.0,"prior_10_amount_std":40.0,'
        '"seconds_since_previous_transaction":30600,'
        '"prior_5_unique_name_dest_count":1.0,"prior_10_unique_name_dest_count":1.0,'
        '"previous_transaction_amount":160.0}'
    )
    fraud_features = (
        '{"card1":1847,"card2":183,"card3":157,"card5":225,'
        '"addr1":312,"addr2":64,"dist1":9,"dist2":8,'
        '"m1":0,"m2":0,"m3":0,"m5":0,"m6":0,"m7":0,"m8":0,"m9":0,'
        '"c1":4.8,"c2":5.5,"c4":3.2,"c7":3.5,"c10":2.8,"c14":3.9,'
        '"d1":0.005,"d2":40.0,"d3":3.5,"d4":4.2,"d5":7.0,'
        '"v1":3.8,"v20":3.5,"v61":3.2,"v81":3.5,"v101":3.4,'
        '"v130":3.2,"v181":4.1,"v201":3.8,"v241":4.2,"v280":3.9,'
        '"v307":4.8,"v320":4.5,'
        '"id_01":-6.5,"id_02":55,"id_05":0.8,"id_11":0.4,'
        '"id_17":9.2,"id_23":11.3,"id_30":5.0,"id_33":0.05,"id_38":3.9,'
        '"prior_5_transaction_count":4.0,"prior_10_transaction_count":7.0,'
        '"prior_5_amount_sum":250.0,"prior_5_amount_mean":50.0,"prior_5_amount_std":12.0,'
        '"prior_10_amount_sum":480.0,"prior_10_amount_mean":48.0,"prior_10_amount_std":10.0,'
        '"seconds_since_previous_transaction":18,'
        '"prior_5_unique_name_dest_count":5.0,"prior_10_unique_name_dest_count":9.0,'
        '"previous_transaction_amount":48.0}'
    )
    return textwrap.dedent(f"""
        #!/bin/bash
        set -euo pipefail

        QUEUE_URL="{queue_url}"
        REGION="{region}"
        COUNT={count}
        FRAUD_PCT={fraud_pct}

        CHANNELS=(web mobile atm pos)
        COUNTRIES=(AR BR CL UY MX)
        CURRENCIES=(ARS BRL USD)

        NORMAL_FEATURES='{normal_features}'
        FRAUD_FEATURES='{fraud_features}'

        for i in $(seq 1 $COUNT); do
            TX_ID=$(cat /proc/sys/kernel/random/uuid)
            USER_ID="u-$(( RANDOM % 50 + 1 ))"
            CHANNEL="${{CHANNELS[$(( RANDOM % ${{#CHANNELS[@]}} ))]}}"
            COUNTRY="${{COUNTRIES[$(( RANDOM % ${{#COUNTRIES[@]}} ))]}}"
            CURRENCY="${{CURRENCIES[$(( RANDOM % ${{#CURRENCIES[@]}} ))]}}"
            TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            DEST="acc-$(( RANDOM % 9000 + 1000 ))"

            if [ $(( RANDOM % 100 )) -lt $FRAUD_PCT ]; then
                # Fraudulent: drain origin account into a fresh destination
                OLD_BAL_ORG=$(( RANDOM % 150000 + 50000 ))
                AMOUNT=$OLD_BAL_ORG
                NEW_BAL_ORIG=0
                OLD_BAL_DEST=0
                NEW_BAL_DEST=$AMOUNT
                TX_TYPE="FRAUD"
                FEATURES="$FRAUD_FEATURES"
            else
                # Normal: small spend, balances correlate correctly
                OLD_BAL_ORG=$(( RANDOM % 50000 + 1000 ))
                AMOUNT=$(( RANDOM % (OLD_BAL_ORG / 2) + 100 ))
                NEW_BAL_ORIG=$(( OLD_BAL_ORG - AMOUNT ))
                OLD_BAL_DEST=$(( RANDOM % 20000 ))
                NEW_BAL_DEST=$(( OLD_BAL_DEST + AMOUNT ))
                TX_TYPE="normal"
                FEATURES="$NORMAL_FEATURES"
            fi

            MSG=$(printf '{{"transaction_id":"%s","user_id":"%s","amount":%d,"currency":"%s","timestamp":"%s","channel":"%s","destination_account":"%s","country":"%s","oldbalance_org":%d,"newbalance_orig":%d,"oldbalance_dest":%d,"newbalance_dest":%d,"features":%s}}' \\
                "$TX_ID" "$USER_ID" "$AMOUNT" "$CURRENCY" "$TIMESTAMP" "$CHANNEL" "$DEST" "$COUNTRY" \\
                "$OLD_BAL_ORG" "$NEW_BAL_ORIG" "$OLD_BAL_DEST" "$NEW_BAL_DEST" "$FEATURES")

            aws sqs send-message --region "$REGION" --queue-url "$QUEUE_URL" --message-body "$MSG" > /dev/null
            echo "sent $i/$COUNT  [$TX_TYPE]  $TX_ID  amount=$AMOUNT"
        done

        echo "Done: $COUNT transaction(s) enqueued."
    """).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stack",       default="itba-tp-fraud-onprem-strongswan", help="CloudFormation stack name for the on-prem EC2")
    parser.add_argument("--region",      default="us-east-1")
    parser.add_argument("--count",      type=int, default=5,  help="Number of transactions to send")
    parser.add_argument("--fraud-pct", type=int, default=20, help="Percentage of transactions with fraud pattern (0-100)")
    parser.add_argument("--queue-url",   default="", help="Override SQS queue URL (default: read from terraform output)")
    parser.add_argument("--instance-id", default="", help="Override EC2 instance ID (default: read from CloudFormation)")
    args = parser.parse_args()

    region      = args.region
    instance_id = args.instance_id or get_instance_id(args.stack, region)
    queue_url   = args.queue_url   or get_queue_url(region)

    print(f"Instance  : {instance_id}")
    print(f"Queue     : {queue_url}")
    print(f"Count     : {args.count}")
    print(f"Fraud pct : {args.fraud_pct}%\n")

    ec2_script = build_ec2_script(queue_url, region, args.count, args.fraud_pct)
    command = f"bash << 'BEOF'\n{ec2_script}\nBEOF"

    ssm    = boto3.client("ssm", region_name=region)
    resp   = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [command]},
        Comment=f"send-test-tx count={args.count} fraud_pct={args.fraud_pct}",
    )
    cmd_id = resp["Command"]["CommandId"]
    print(f"SSM command ID: {cmd_id}")
    print("Waiting", end="", flush=True)

    for _ in range(60):
        time.sleep(3)
        inv    = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
        status = inv["Status"]
        print(".", end="", flush=True)
        if status in ("Success", "Failed", "Cancelled", "TimedOut"):
            print(f" {status}\n")
            stdout = inv.get("StandardOutputContent", "").strip()
            stderr = inv.get("StandardErrorContent", "").strip()
            if stdout:
                print(stdout)
            if stderr:
                print("STDERR:", stderr, file=sys.stderr)
            sys.exit(0 if status == "Success" else 1)

    print(" timed out waiting for SSM command")
    sys.exit(1)


if __name__ == "__main__":
    main()
