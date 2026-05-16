import json
import logging
import os

import psycopg2
import psycopg2.extras

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_conn = None


def _get_conn():
    global _conn
    if _conn is None or _conn.closed:
        _conn = psycopg2.connect(
            host=os.environ["DB_HOST"],
            port=int(os.environ["DB_PORT"]),
            dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"],
            password=os.environ["DB_PASSWORD"],
            sslmode="require",
            connect_timeout=5,
        )
    return _conn


def _ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS transactions (
                id             SERIAL PRIMARY KEY,
                transaction_id VARCHAR(255) UNIQUE NOT NULL,
                user_id        VARCHAR(255),
                amount         NUMERIC(15, 2),
                currency       VARCHAR(10),
                country        VARCHAR(100),
                channel        VARCHAR(50),
                fraud_score    FLOAT,
                is_fraud       BOOLEAN,
                decision       VARCHAR(20),
                processed_at   TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_tx_processed_at ON transactions (processed_at DESC);
            CREATE INDEX IF NOT EXISTS idx_tx_is_fraud     ON transactions (is_fraud);
        """)
    conn.commit()


def handler(event, context):
    conn = _get_conn()
    _ensure_schema(conn)

    processed = 0
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            payload = json.loads(body["Message"]) if "Message" in body else body

            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO transactions
                        (transaction_id, user_id, fraud_score, is_fraud, decision)
                    VALUES
                        (%(transaction_id)s, %(user_id)s, %(fraud_score)s,
                         %(is_fraud)s, %(decision)s)
                    ON CONFLICT (transaction_id) DO NOTHING
                    """,
                    {
                        "transaction_id": payload.get("transaction_id"),
                        "user_id": payload.get("user_id"),
                        "fraud_score": payload.get("fraud_score"),
                        "is_fraud": bool(payload.get("is_fraud")),
                        "decision": "block" if payload.get("is_fraud") else "allow",
                    },
                )
            conn.commit()
            logger.info(json.dumps({
                "action": "fraud_result_stored",
                "transaction_id": payload.get("transaction_id"),
                "is_fraud": payload.get("is_fraud"),
            }))
            processed += 1
        except Exception as exc:
            conn.rollback()
            logger.error(json.dumps({"action": "processing_error", "error": str(exc)}))
            raise

    return {"processed": processed}
