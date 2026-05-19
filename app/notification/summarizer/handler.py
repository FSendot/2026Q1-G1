import html
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


def _aggregate_events(events):
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
    return rows, currencies, users, countries, channels, highest_risk


def _format_amount(amount):
    return f"{amount:,.2f}"


def _build_summary_text(
    rows,
    currencies,
    users,
    countries,
    channels,
    highest_risk,
    *,
    interval_minutes,
    generated_at,
    dashboard_url,
    truncated,
    raw_messages,
):

    lines = [
        "Resumen de fraude — Dashboard ITBA",
        "",
        f"Generado: {generated_at.isoformat()}",
        f"Ventana: últimos {interval_minutes} minutos",
        f"Transacciones fraudulentas en este resumen: {len(rows)}",
    ]
    if truncated:
        lines.append(
            f"(Se alcanzó el límite de {len(rows)} eventos por email; puede haber más en cola.)"
        )
    lines.extend(
        [
            "",
            "Abrir dashboard:",
            dashboard_url or "(URL no configurada)",
            "",
            "Monto total por moneda",
            "----------------------",
        ]
    )
    if currencies:
        for currency, amount in sorted(currencies.items()):
            lines.append(f"{currency:>6}  {_format_amount(amount)}")
    else:
        lines.append("Sin montos disponibles")

    lines.extend(["", "Usuarios con más eventos", "-----------------------"])
    for user_id, count in users.most_common(5):
        lines.append(f"{user_id:<32} {count:>4}")

    lines.extend(["", "Países / canales principales", "----------------------------"])
    for country, count in countries.most_common(5):
        lines.append(f"País {country:<24} {count:>4}")
    for channel, count in channels.most_common(5):
        lines.append(f"Canal {channel:<23} {count:>4}")

    lines.extend(["", "Transacciones de mayor riesgo", "------------------------------"])
    for row in highest_risk:
        lines.append(
            f"{str(row.get('transaction_id') or '')[:18]:<18} "
            f"{str(row.get('user_id') or '')[:18]:<18} "
            f"{_format_amount(_parse_decimal(row.get('amount'))):>12} "
            f"{str(row.get('currency') or '')[:4]:<4} "
            f"{str(row.get('country') or '')[:8]:<8} "
            f"score={float(row.get('fraud_score') or 0):.3f}"
        )

    if raw_messages > len(rows):
        lines.append("")
        lines.append(f"Mensajes SQS procesados: {raw_messages}")

    return "\n".join(lines)


def _build_summary_html(
    rows,
    currencies,
    users,
    countries,
    channels,
    highest_risk,
    *,
    interval_minutes,
    generated_at,
    dashboard_url,
    truncated,
):

    currency_rows = "".join(
        f"<tr><td>{html.escape(currency)}</td><td align='right'>{html.escape(_format_amount(amount))}</td></tr>"
        for currency, amount in sorted(currencies.items())
    ) or "<tr><td colspan='2'>Sin montos disponibles</td></tr>"

    user_rows = "".join(
        f"<tr><td>{html.escape(user_id)}</td><td align='right'>{count}</td></tr>"
        for user_id, count in users.most_common(5)
    ) or "<tr><td colspan='2'>—</td></tr>"

    country_rows = "".join(
        f"<tr><td>País {html.escape(country)}</td><td align='right'>{count}</td></tr>"
        for country, count in countries.most_common(5)
    )
    channel_rows = "".join(
        f"<tr><td>Canal {html.escape(channel)}</td><td align='right'>{count}</td></tr>"
        for channel, count in channels.most_common(5)
    )

    risk_rows = "".join(
        "<tr>"
        f"<td>{html.escape(str(row.get('transaction_id') or '')[:18])}</td>"
        f"<td>{html.escape(str(row.get('user_id') or '')[:18])}</td>"
        f"<td align='right'>{html.escape(_format_amount(_parse_decimal(row.get('amount'))))}</td>"
        f"<td>{html.escape(str(row.get('currency') or ''))}</td>"
        f"<td>{html.escape(str(row.get('country') or ''))}</td>"
        f"<td>{html.escape(str(row.get('channel') or ''))}</td>"
        f"<td align='right'>{float(row.get('fraud_score') or 0):.3f}</td>"
        "</tr>"
        for row in highest_risk
    ) or "<tr><td colspan='7'>Sin eventos</td></tr>"

    dashboard_block = ""
    if dashboard_url:
        safe_url = html.escape(dashboard_url, quote=True)
        dashboard_block = f"""
          <p style="margin:24px 0 0;text-align:center;">
            <a href="{safe_url}"
               style="display:inline-block;background:#1d4ed8;color:#ffffff;text-decoration:none;
                      padding:12px 22px;border-radius:8px;font-weight:600;font-size:15px;">
              Abrir dashboard
            </a>
          </p>
          <p style="margin:10px 0 0;text-align:center;font-size:12px;color:#64748b;word-break:break-all;">
            {html.escape(dashboard_url)}
          </p>
        """

    truncated_note = ""
    if truncated:
        truncated_note = (
            "<p style='margin:12px 0 0;padding:10px 12px;background:#fff7ed;"
            "border:1px solid #fdba74;border-radius:8px;color:#9a3412;font-size:13px;'>"
            f"Este resumen incluye hasta {len(rows)} eventos. Puede haber más alertas pendientes "
            "para el próximo correo."
            "</p>"
        )

    return f"""<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Resumen de fraude</title>
</head>
<body style="margin:0;padding:0;background:#f1f5f9;font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#0f172a;">
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f1f5f9;padding:24px 12px;">
    <tr>
      <td align="center">
        <table role="presentation" width="600" cellspacing="0" cellpadding="0"
               style="max-width:600px;background:#ffffff;border-radius:12px;overflow:hidden;
                      box-shadow:0 8px 24px rgba(15,23,42,.08);">
          <tr>
            <td style="background:linear-gradient(135deg,#1e3a8a,#1d4ed8);padding:28px 32px;color:#ffffff;">
              <p style="margin:0;font-size:12px;letter-spacing:.08em;text-transform:uppercase;opacity:.85;">
                ITBA · Fraud Detector
              </p>
              <h1 style="margin:8px 0 0;font-size:24px;font-weight:700;line-height:1.25;">
                Resumen de fraude
              </h1>
              <p style="margin:10px 0 0;font-size:14px;opacity:.92;">
                Ventana de {interval_minutes} minutos · {generated_at.strftime("%d/%m/%Y %H:%M UTC")}
              </p>
            </td>
          </tr>
          <tr>
            <td style="padding:28px 32px;">
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0"
                     style="background:#f8fafc;border:1px solid #e2e8f0;border-radius:10px;">
                <tr>
                  <td style="padding:18px 20px;">
                    <p style="margin:0;font-size:13px;color:#64748b;text-transform:uppercase;letter-spacing:.06em;">
                      Transacciones fraudulentas
                    </p>
                    <p style="margin:6px 0 0;font-size:32px;font-weight:700;color:#b91c1c;line-height:1;">
                      {len(rows)}
                    </p>
                  </td>
                </tr>
              </table>
              {truncated_note}
              {dashboard_block}
              <h2 style="margin:28px 0 10px;font-size:16px;color:#0f172a;">Monto por moneda</h2>
              <table width="100%" cellspacing="0" cellpadding="0"
                     style="border-collapse:collapse;font-size:13px;">
                <tr style="background:#f8fafc;">
                  <th align="left" style="padding:8px 10px;border-bottom:1px solid #e2e8f0;">Moneda</th>
                  <th align="right" style="padding:8px 10px;border-bottom:1px solid #e2e8f0;">Monto</th>
                </tr>
                {currency_rows}
              </table>
              <h2 style="margin:24px 0 10px;font-size:16px;">Usuarios con más eventos</h2>
              <table width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse;font-size:13px;">
                {user_rows}
              </table>
              <h2 style="margin:24px 0 10px;font-size:16px;">Países y canales</h2>
              <table width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse;font-size:13px;">
                {country_rows}
                {channel_rows}
              </table>
              <h2 style="margin:24px 0 10px;font-size:16px;">Mayor riesgo</h2>
              <table width="100%" cellspacing="0" cellpadding="0"
                     style="border-collapse:collapse;font-size:12px;">
                <tr style="background:#f8fafc;">
                  <th align="left" style="padding:6px 8px;border-bottom:1px solid #e2e8f0;">TX</th>
                  <th align="left" style="padding:6px 8px;border-bottom:1px solid #e2e8f0;">Usuario</th>
                  <th align="right" style="padding:6px 8px;border-bottom:1px solid #e2e8f0;">Monto</th>
                  <th align="left" style="padding:6px 8px;border-bottom:1px solid #e2e8f0;">Mon.</th>
                  <th align="left" style="padding:6px 8px;border-bottom:1px solid #e2e8f0;">País</th>
                  <th align="left" style="padding:6px 8px;border-bottom:1px solid #e2e8f0;">Canal</th>
                  <th align="right" style="padding:6px 8px;border-bottom:1px solid #e2e8f0;">Score</th>
                </tr>
                {risk_rows}
              </table>
            </td>
          </tr>
          <tr>
            <td style="padding:0 32px 24px;font-size:12px;color:#94a3b8;line-height:1.5;">
              Correo automático del laboratorio Fraud Detector. No respondas a este mensaje.
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>"""


def _build_summary(events, *, interval_minutes, dashboard_url, max_messages):
    rows, currencies, users, countries, channels, highest_risk = _aggregate_events(events)
    generated_at = datetime.now(timezone.utc).replace(microsecond=0)
    truncated = len(events) >= max_messages and len(rows) >= max_messages

    text_body = _build_summary_text(
        rows,
        currencies,
        users,
        countries,
        channels,
        highest_risk,
        interval_minutes=interval_minutes,
        generated_at=generated_at,
        dashboard_url=dashboard_url,
        truncated=truncated,
        raw_messages=len(events),
    )
    html_body = _build_summary_html(
        rows,
        currencies,
        users,
        countries,
        channels,
        highest_risk,
        interval_minutes=interval_minutes,
        generated_at=generated_at,
        dashboard_url=dashboard_url,
        truncated=truncated,
    )
    return text_body, html_body, len(rows)


def _publish_summary(topic_arn, subject, text_body, html_body):
    sns.publish(
        TopicArn=topic_arn,
        Subject=subject,
        Message=json.dumps(
            {
                "default": text_body,
                "email": html_body,
            }
        ),
        MessageStructure="json",
    )


def handler(event, context):
    queue_url = os.environ["FRAUD_ALERT_QUEUE_URL"]
    topic_arn = os.environ["SUMMARY_TOPIC_ARN"]
    max_messages = int(os.environ.get("MAX_MESSAGES_PER_RUN", "500"))
    interval_minutes = int(os.environ.get("SUMMARY_INTERVAL_MINUTES", "7"))
    dashboard_url = os.environ.get("DASHBOARD_URL", "").strip()

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

    text_body, html_body, event_count = _build_summary(
        events,
        interval_minutes=interval_minutes,
        dashboard_url=dashboard_url,
        max_messages=max_messages,
    )
    if event_count == 0:
        logger.info(json.dumps({"action": "fraud_summary_no_valid_events", "messages": len(messages)}))
        _delete_messages(queue_url, messages)
        return {"published": False, "messages": len(messages), "events": 0}

    _publish_summary(
        topic_arn,
        f"Resumen de fraude: {event_count} evento(s)",
        text_body,
        html_body,
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
