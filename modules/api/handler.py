import json
import logging
import os

import psycopg2
import psycopg2.extras

logger = logging.getLogger()
logger.setLevel(logging.INFO)

HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
}

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


def _health():
    try:
        conn = _get_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        return {"statusCode": 200, "headers": HEADERS, "body": json.dumps({"status": "ok"})}
    except Exception as exc:
        logger.error(str(exc))
        return {"statusCode": 503, "headers": HEADERS, "body": json.dumps({"status": "error"})}


def _stats():
    conn = _get_conn()
    _ensure_schema(conn)
    with conn.cursor() as cur:
        cur.execute("""
            SELECT
                COUNT(*)                                        AS total,
                COUNT(*) FILTER (WHERE is_fraud = TRUE)        AS blocked,
                COUNT(*) FILTER (WHERE is_fraud = FALSE)       AS allowed,
                COUNT(*) FILTER (WHERE decision = 'challenge') AS challenged
            FROM transactions
        """)
        row = cur.fetchone()
    return {
        "statusCode": 200,
        "headers": HEADERS,
        "body": json.dumps({
            "total": row[0],
            "blocked": row[1],
            "allowed": row[2],
            "challenged": row[3],
        }),
    }


def _transactions(limit):
    conn = _get_conn()
    _ensure_schema(conn)
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """
            SELECT transaction_id, user_id, amount, country,
                   fraud_score, is_fraud, decision, processed_at
            FROM   transactions
            ORDER  BY processed_at DESC
            LIMIT  %s
            """,
            (limit,),
        )
        rows = cur.fetchall()

    result = []
    for row in rows:
        r = dict(row)
        if r.get("processed_at"):
            r["processed_at"] = r["processed_at"].isoformat()
        if r.get("amount") is not None:
            r["amount"] = float(r["amount"])
        result.append(r)

    return {
        "statusCode": 200,
        "headers": HEADERS,
        "body": json.dumps({"transactions": result, "count": len(result)}),
    }


def handler(event, context):
    path = event.get("rawPath", "")
    query = event.get("queryStringParameters") or {}

    logger.info(json.dumps({"action": "api_request", "path": path}))

    # Accept paths with or without /api/ prefix for dashboard compatibility
    if path in ("/health", "/api/health"):
        return _health()

    if path in ("/stats", "/api/stats"):
        try:
            return _stats()
        except Exception as exc:
            logger.exception("stats query failed")
            return {"statusCode": 500, "headers": HEADERS, "body": json.dumps({"error": str(exc)})}

    if path in ("/transactions", "/api/transactions"):
        limit = min(int(query.get("limit", 20)), 100)
        try:
            return _transactions(limit)
        except Exception as exc:
            logger.exception("transactions query failed")
            return {"statusCode": 500, "headers": HEADERS, "body": json.dumps({"error": str(exc)})}

    return {"statusCode": 404, "headers": HEADERS, "body": json.dumps({"error": "not found"})}
