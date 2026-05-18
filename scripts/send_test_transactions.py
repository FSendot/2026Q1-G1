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
from string import Template
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
    # The remote EC2 only needs Python stdlib plus the AWS CLI. Messages are sent
    # in SQS batches of 10 so 50k transaction runs finish in a reasonable window.
    template = Template("""
        #!/bin/bash
        set -euo pipefail

        export QUEUE_URL="$queue_url"
        export REGION="$region"
        export COUNT="$count"
        export FRAUD_PCT="$fraud_pct"

        python3 <<'PY'
import datetime as dt
import json
import math
import os
import random
import subprocess
import tempfile
import uuid

queue_url = os.environ["QUEUE_URL"]
region = os.environ["REGION"]
count = int(os.environ["COUNT"])
fraud_pct = max(0, min(100, int(os.environ["FRAUD_PCT"])))

random.seed()
countries = ["AR", "BR", "CL", "UY", "MX", "CO", "PE", "US"]
channels = ["web", "mobile", "atm", "pos", "api"]
currency_by_country = {
    "AR": "ARS",
    "BR": "BRL",
    "CL": "CLP",
    "UY": "UYU",
    "MX": "MXN",
    "CO": "COP",
    "PE": "PEN",
    "US": "USD",
}
normal_scenarios = ["trusted_repeat", "returning_daily", "new_user_sparse"]
fraud_scenarios = ["account_drain", "country_shift", "device_shift", "merchant_fanout", "micro_amount_card_testing"]


def r(minimum, maximum, digits=3):
    return round(random.uniform(minimum, maximum), digits)


def choose_user():
    # A larger stable-user pool gives DynamoDB enough repeat traffic for
    # amount/country/channel/destination profiles while still producing new users.
    if random.random() < 0.85:
        return f"u-{random.randint(1, 2000):04d}"
    return f"new-{uuid.uuid4().hex[:10]}"


def user_home_country(user_id):
    return countries[sum(ord(char) for char in user_id) % len(countries)]


def alternate_country(home_country):
    options = [country for country in countries if country != home_country]
    return random.choice(options)


def feature_blob(is_fraud, amount, scenario):
    if is_fraud:
        prior_mean = r(20, 900)
        seconds_since = random.choice([r(5, 90), r(90, 900), r(900, 3600)])
        dest_unique_5 = random.randint(3, 5)
        dest_unique_10 = random.randint(dest_unique_5, 10)
        base = {
            "card1": random.randint(1500, 2100),
            "card2": random.randint(120, 220),
            "card3": random.randint(140, 190),
            "card5": random.randint(210, 240),
            "addr1": random.randint(260, 380),
            "addr2": random.randint(55, 75),
            "dist1": r(4, 18),
            "dist2": r(3, 16),
            "m1": 0,
            "m2": 0,
            "m3": 0,
            "m5": random.randint(0, 1),
            "m6": 0,
            "m7": 0,
            "m8": 0,
            "m9": 0,
            "c1": r(3.0, 7.0),
            "c2": r(3.5, 8.0),
            "c4": r(2.0, 5.5),
            "c7": r(2.0, 6.0),
            "c10": r(2.0, 5.0),
            "c14": r(2.5, 6.5),
            "d1": r(0.001, 0.08),
            "d2": r(12.0, 70.0),
            "d3": r(2.0, 8.0),
            "d4": r(2.0, 9.0),
            "d5": r(3.0, 12.0),
            "id_01": r(-9.0, -4.5),
            "id_02": r(20, 95),
            "id_05": r(0.1, 1.6),
            "id_11": r(0.1, 1.2),
            "id_17": r(6.0, 12.0),
            "id_23": r(7.0, 14.0),
            "id_30": r(3.0, 7.0),
            "id_33": r(0.01, 1.0),
            "id_38": r(2.5, 5.5),
            "previous_transaction_amount": r(5, max(50, prior_mean)),
            "prior_5_transaction_count": random.randint(2, 5),
            "prior_10_transaction_count": random.randint(5, 10),
            "prior_5_amount_sum": r(prior_mean * 2, prior_mean * 5),
            "prior_5_amount_mean": prior_mean,
            "prior_5_amount_std": r(5, max(8, prior_mean * 0.35)),
            "prior_10_amount_sum": r(prior_mean * 5, prior_mean * 10),
            "prior_10_amount_mean": r(prior_mean * 0.8, prior_mean * 1.2),
            "prior_10_amount_std": r(8, max(12, prior_mean * 0.45)),
            "seconds_since_previous_transaction": seconds_since,
            "prior_5_unique_name_dest_count": dest_unique_5,
            "prior_10_unique_name_dest_count": dest_unique_10,
        }
        v_min, v_max = (3.0, 5.5)
    else:
        prior_mean = max(25, amount * r(0.75, 1.3))
        seconds_since = random.choice([r(3600, 21600), r(21600, 86400), r(86400, 604800)])
        base = {
            "card1": random.randint(900, 1500),
            "card2": random.randint(90, 170),
            "card3": random.randint(150, 180),
            "card5": random.randint(215, 230),
            "addr1": random.randint(180, 260),
            "addr2": random.randint(50, 65),
            "dist1": r(0, 2),
            "dist2": r(0, 2),
            "m1": 1,
            "m2": 1,
            "m3": 1,
            "m5": 1,
            "m6": 1,
            "m7": 1,
            "m8": 1,
            "m9": 1,
            "c1": r(0.4, 2.0),
            "c2": r(0.4, 2.0),
            "c4": r(0.0, 0.9),
            "c7": r(0.2, 1.8),
            "c10": r(0.2, 1.5),
            "c14": r(0.1, 1.2),
            "d1": r(2.0, 18.0),
            "d2": r(0.1, 3.0),
            "d3": r(0.1, 2.0),
            "d4": r(0.1, 2.0),
            "d5": r(0.1, 1.5),
            "id_01": r(-3.5, -0.2),
            "id_02": r(90, 180),
            "id_05": r(1.5, 5.0),
            "id_11": r(1.2, 4.0),
            "id_17": r(0.1, 2.0),
            "id_23": r(0.1, 1.5),
            "id_30": r(0.3, 2.0),
            "id_33": r(8.0, 24.0),
            "id_38": r(0.2, 1.5),
            "previous_transaction_amount": r(prior_mean * 0.6, prior_mean * 1.4),
            "prior_5_transaction_count": random.randint(1, 5),
            "prior_10_transaction_count": random.randint(3, 10),
            "prior_5_amount_sum": r(prior_mean * 2, prior_mean * 5),
            "prior_5_amount_mean": prior_mean,
            "prior_5_amount_std": r(2, max(4, prior_mean * 0.25)),
            "prior_10_amount_sum": r(prior_mean * 5, prior_mean * 10),
            "prior_10_amount_mean": r(prior_mean * 0.85, prior_mean * 1.15),
            "prior_10_amount_std": r(4, max(6, prior_mean * 0.30)),
            "seconds_since_previous_transaction": seconds_since,
            "prior_5_unique_name_dest_count": random.randint(1, 2),
            "prior_10_unique_name_dest_count": random.randint(1, 3),
        }
        v_min, v_max = (0.05, 0.9)

    for name in ("v1", "v20", "v61", "v81", "v101", "v130", "v181", "v201", "v241", "v280", "v307", "v320"):
        base[name] = r(v_min, v_max)
    base["amount"] = amount
    base["amount_log1p"] = round(math.log1p(amount), 6)
    return base


def make_transaction(index):
    is_fraud = random.randrange(100) < fraud_pct
    scenario = random.choice(fraud_scenarios if is_fraud else normal_scenarios)
    user_id = choose_user()
    home_country = user_home_country(user_id)
    country = alternate_country(home_country) if scenario in ("country_shift", "account_drain") else home_country
    currency = "USD" if is_fraud and random.random() < 0.35 else currency_by_country[country]
    channel = random.choice(["web", "mobile", "api"]) if is_fraud else random.choice(channels)
    timestamp = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=random.randint(0, 7 * 24 * 3600))).strftime("%Y-%m-%dT%H:%M:%SZ")

    if is_fraud and scenario == "micro_amount_card_testing":
        amount = r(1, 35, 2)
        oldbalance_org = r(100, 5000, 2)
    elif is_fraud:
        oldbalance_org = r(50000, 250000, 2)
        amount = oldbalance_org if scenario == "account_drain" else r(2500, min(180000, oldbalance_org), 2)
    else:
        oldbalance_org = r(1000, 80000, 2)
        amount = r(25, max(50, min(oldbalance_org * 0.45, 3500)), 2)

    newbalance_orig = max(0, round(oldbalance_org - amount, 2))
    oldbalance_dest = 0 if is_fraud and scenario in ("account_drain", "merchant_fanout") else r(0, 40000, 2)
    newbalance_dest = round(oldbalance_dest + amount, 2)
    destination = f"acc-{random.randint(1000, 999999)}" if is_fraud else f"merchant-{random.randint(1, 600):04d}"

    return {
        "transaction_id": str(uuid.uuid4()),
        "user_id": user_id,
        "amount": amount,
        "currency": currency,
        "timestamp": timestamp,
        "channel": channel,
        "destination_account": destination,
        "country": country,
        "oldbalance_org": oldbalance_org,
        "newbalance_orig": newbalance_orig,
        "oldbalance_dest": oldbalance_dest,
        "newbalance_dest": newbalance_dest,
        "features": feature_blob(is_fraud, amount, scenario),
    }, scenario


def send_batch(entries):
    payload = {"QueueUrl": queue_url, "Entries": entries}
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(payload, handle)
        path = handle.name
    try:
        subprocess.run(
            ["aws", "sqs", "send-message-batch", "--region", region, "--cli-input-json", f"file://{path}"],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    finally:
        os.unlink(path)


batch = []
scenario_counts = {}
fraud_count = 0
for index in range(1, count + 1):
    message, scenario = make_transaction(index)
    scenario_counts[scenario] = scenario_counts.get(scenario, 0) + 1
    if scenario in fraud_scenarios:
        fraud_count += 1
    batch.append({"Id": f"msg{len(batch)}", "MessageBody": json.dumps(message, separators=(",", ":"))})

    if len(batch) == 10:
        send_batch(batch)
        batch = []
    if index % 1000 == 0 or index == count:
        print(f"sent {index}/{count}", flush=True)

if batch:
    send_batch(batch)

print(f"Done: {count} transaction(s) enqueued; fraud-pattern={fraud_count} ({fraud_count / max(count, 1) * 100:.1f}%).")
print("Scenario counts:", json.dumps(scenario_counts, sort_keys=True))
PY
    """)
    return textwrap.dedent(template.substitute(
        queue_url=queue_url,
        region=region,
        count=count,
        fraud_pct=fraud_pct,
    )).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stack",       default="itba-tp-fraud-onprem-strongswan", help="CloudFormation stack name for the on-prem EC2")
    parser.add_argument("--region",      default="us-east-1")
    parser.add_argument("--count",      type=int, default=50000,  help="Number of transactions to send")
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

    max_wait_seconds = max(900, min(7200, args.count // 10 + 600))
    for _ in range(max_wait_seconds // 3):
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
