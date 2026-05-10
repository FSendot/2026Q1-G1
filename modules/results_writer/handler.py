import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    processed = 0
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            # SNS wraps the original payload inside body["Message"]
            payload = json.loads(body["Message"]) if "Message" in body else body
            logger.info(json.dumps({
                "action": "fraud_result_received",
                "transaction_id": payload.get("transaction_id"),
                "fraud_score": payload.get("fraud_score"),
                "is_fraud": payload.get("is_fraud"),
                "user_id": payload.get("user_id"),
            }))
            # TODO: write to RDS — requires psycopg2 Lambda layer + schema migration
            processed += 1
        except Exception as exc:
            logger.error(json.dumps({"action": "processing_error", "error": str(exc)}))
            raise
    return {"processed": processed}
