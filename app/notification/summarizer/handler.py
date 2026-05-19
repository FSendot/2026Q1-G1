import json
import logging
import os
from collections import Counter, defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs = boto3.client("sqs")
sns = boto3.client("sns")


def _parse_decimal(value):
    try:
        return Decimal(str(value or "0"))
    except (InvalidOperation, ValueError):
        return Decimal("0")


def _parse_payload(body):
    payload = json.loads(body)
    if "Message" in payload:
        return json.loads(payload["Message"])
    return payload


def _receive_messages(queue_url, max_messages):
    messages = []
    while len(messages) < max_messages:
        batch_size = min(10, max_messages - len(messages))
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=batch_size,
            WaitTimeSeconds=1,
        )
        batch = response.get("Messages", [])
        if not batch:
            break
        messages.extend(batch)
    return messages


def _delete_messages(queue_url, messages):
    for start in range(0, len(messages), 10):
        entries = [
            {"Id": str(index), "ReceiptHandle": message["ReceiptHandle"]}
            for index, message in enumerate(messages[start : start + 10])
        ]
        if entries:
            sqs.delete_message_batch(QueueUrl=queue_url, Entries=entries)


def _build_summary(events, *, interval_minutes):
    deduped = {}
    for event in events:
        tx_id = str(event.get("transaction_id") or "")
        if tx_id:
            deduped[tx_id] = event

    rows = list(deduped.values())
    currencies = defaultdict(Decimal)
    users = Counter()
    countries = Counter()
    channels = Counter()

    for row in rows:
        currency = str(row.get("currency") or "N/A")
        currencies[currency] += _parse_decimal(row.get("amount"))
        users[str(row.get("user_id") or "N/A")] += 1
        countries[str(row.get("country") or "N/A")] += 1
        channels[str(row.get("channel") or "N/A")] += 1

    highest_risk = sorted(rows, key=lambda item: float(item.get("fraud_score") or 0), reverse=True)[:10]
    now = datetime.now(timezone.utc).replace(microsecond=0)

    lines = [
        "Resumen de fraude - Dashboard ITBA",
        "=" * 38,
        f"Generado: {now.isoformat()}",
        f"Ventana configurada: {interval_minutes} minutos",
        f"Transacciones fraudulentas: {len(rows)}",
        "",
        "Monto total por moneda",
        "-" * 22,
    ]
    if currencies:
        for currency, amount in sorted(currencies.items()):
            lines.append(f"{currency:>6}  {amount:,.2f}")
    else:
        lines.append("Sin montos disponibles")

    lines.extend(["", "Usuarios con mas eventos", "-" * 23])
    for user_id, count in users.most_common(5):
        lines.append(f"{user_id:<32} {count:>4}")

    lines.extend(["", "Paises / canales principales", "-" * 28])
    for country, count in countries.most_common(5):
        lines.append(f"Pais {country:<24} {count:>4}")
    for channel, count in channels.most_common(5):
        lines.append(f"Canal {channel:<23} {count:>4}")

    lines.extend(["", "Transacciones de mayor riesgo", "-" * 30])
    header = f"{'TX':<18} {'USER':<18} {'AMOUNT':>12} {'CUR':<4} {'COUNTRY':<8} {'CHANNEL':<10} {'SCORE':>6}"
    lines.append(header)
    lines.append("-" * len(header))
    for row in highest_risk:
        lines.append(
            f"{str(row.get('transaction_id') or '')[:18]:<18} "
            f"{str(row.get('user_id') or '')[:18]:<18} "
            f"{_parse_decimal(row.get('amount')):>12,.2f} "
            f"{str(row.get('currency') or '')[:4]:<4} "
            f"{str(row.get('country') or '')[:8]:<8} "
            f"{str(row.get('channel') or '')[:10]:<10} "
            f"{float(row.get('fraud_score') or 0):>6.3f}"
        )

    lines.extend(["", "Ver el detalle completo en el dashboard."])
    return "\n".join(lines), len(rows)


def handler(event, context):
    queue_url = os.environ["FRAUD_ALERT_QUEUE_URL"]
    topic_arn = os.environ["SUMMARY_TOPIC_ARN"]
    max_messages = int(os.environ.get("MAX_MESSAGES_PER_RUN", "500"))
    interval_minutes = int(os.environ.get("SUMMARY_INTERVAL_MINUTES", "7"))

    messages = _receive_messages(queue_url, max_messages)
    if not messages:
        logger.info(json.dumps({"action": "fraud_summary_empty"}))
        return {"published": False, "messages": 0}

    events = []
    for message in messages:
        try:
            events.append(_parse_payload(message["Body"]))
        except Exception as exc:
            logger.error(json.dumps({"action": "fraud_summary_parse_error", "error": str(exc)}))

    summary, event_count = _build_summary(events, interval_minutes=interval_minutes)
    if event_count == 0:
        logger.info(json.dumps({"action": "fraud_summary_no_valid_events", "messages": len(messages)}))
        _delete_messages(queue_url, messages)
        return {"published": False, "messages": len(messages), "events": 0}

    sns.publish(
        TopicArn=topic_arn,
        Subject=f"Resumen de fraude: {event_count} evento(s)",
        Message=summary,
    )
    _delete_messages(queue_url, messages)

    logger.info(
        json.dumps(
            {
                "action": "fraud_summary_published",
                "messages": len(messages),
                "events": event_count,
            }
        )
    )
    return {"published": True, "messages": len(messages), "events": event_count}
