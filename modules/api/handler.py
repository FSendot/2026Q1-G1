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
            CREATE INDEX IF NOT EXISTS idx_tx_user_id      ON transactions (user_id);
            CREATE INDEX IF NOT EXISTS idx_tx_country      ON transactions (country);
            CREATE INDEX IF NOT EXISTS idx_tx_channel      ON transactions (channel);
        """)
    conn.commit()


# ── Helpers ───────────────────────────────────────────────────────────────────

def _ok(data, meta=None):
    body = {"data": data}
    if meta is not None:
        body["meta"] = meta
    return {"statusCode": 200, "headers": HEADERS, "body": json.dumps(body, default=str)}


def _err(status, code, message):
    return {
        "statusCode": status,
        "headers": HEADERS,
        "body": json.dumps({"error": {"code": code, "message": message}}),
    }


def _serialize_row(r):
    out = dict(r)
    for ts_field in ("processed_at", "last_seen", "hour"):
        if out.get(ts_field) is not None:
            out[ts_field] = out[ts_field].isoformat()
    for float_field in ("amount", "avg_fraud_score", "fraud_rate_pct"):
        if out.get(float_field) is not None:
            out[float_field] = float(out[float_field])
    return out


_SORTABLE_TX    = {"amount", "fraud_score", "processed_at"}
_SORTABLE_USERS = {"total_transactions", "fraud_count", "fraud_rate_pct", "avg_fraud_score", "last_seen"}


def _sort_clause(query, valid_cols, default_col, default_dir="DESC"):
    col = query.get("sort_by", default_col)
    if col not in valid_cols:
        col = default_col
    raw_dir = query.get("sort_order", default_dir).upper()
    direction = "DESC" if raw_dir not in ("ASC", "DESC") else raw_dir
    return col, direction


def _build_where(query, extra_filters=None, extra_params=None):
    """Build (filters, params) from shared query-string filter params."""
    filters = list(extra_filters or [])
    params  = list(extra_params  or [])

    if query.get("user_id"):
        filters.append("user_id = %s");  params.append(query["user_id"])
    if query.get("country"):
        filters.append("country = %s");  params.append(query["country"])
    if query.get("channel"):
        filters.append("channel = %s");  params.append(query["channel"])
    if query.get("is_fraud") in ("true", "1"):
        filters.append("is_fraud = TRUE")
    elif query.get("is_fraud") in ("false", "0"):
        filters.append("is_fraud = FALSE")
    if query.get("from"):
        filters.append("processed_at >= %s"); params.append(query["from"])
    if query.get("to"):
        filters.append("processed_at <= %s"); params.append(query["to"])

    where = ("WHERE " + " AND ".join(filters)) if filters else ""
    return where, params


# ── Endpoints ─────────────────────────────────────────────────────────────────

def _health():
    try:
        conn = _get_conn()
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        return _ok({"status": "ok"})
    except Exception as exc:
        logger.error(str(exc))
        return _err(503, "SERVICE_UNAVAILABLE", "Database unreachable")


def _get_stats(query):
    conn = _get_conn()
    _ensure_schema(conn)
    where, params = _build_where(query)
    with conn.cursor() as cur:
        cur.execute(f"""
            SELECT
                COUNT(*)                                        AS total,
                COUNT(*) FILTER (WHERE is_fraud = TRUE)        AS fraud,
                COUNT(*) FILTER (WHERE decision = 'allow')     AS allowed,
                COUNT(*) FILTER (WHERE decision = 'block')     AS blocked,
                COUNT(*) FILTER (WHERE decision = 'challenge') AS challenged,
                ROUND(AVG(fraud_score)::numeric, 4)            AS avg_fraud_score
            FROM transactions
            {where}
        """, params)
        row = cur.fetchone()
    total = row[0] or 0
    fraud = row[1] or 0
    return _ok({
        "total":           total,
        "fraud":           fraud,
        "allowed":         row[2] or 0,
        "blocked":         row[3] or 0,
        "challenged":      row[4] or 0,
        "fraud_rate":      round(fraud / total, 4) if total > 0 else 0.0,
        "avg_fraud_score": float(row[5]) if row[5] is not None else None,
    })


def _get_stats_timeseries(query):
    conn = _get_conn()
    _ensure_schema(conn)

    granularity = query.get("granularity", "hour")
    if granularity not in ("hour", "day"):
        granularity = "hour"

    try:
        days = max(1, min(int(query.get("days", 1)), 90))
    except (ValueError, TypeError):
        days = 1

    where, params = _build_where(query)
    time_clause = f"processed_at >= NOW() - INTERVAL '{days} days'"
    full_where = (where + f" AND {time_clause}") if where else f"WHERE {time_clause}"

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(f"""
            SELECT
                date_trunc('{granularity}', processed_at) AS hour,
                COUNT(*)                                   AS total,
                COUNT(*) FILTER (WHERE is_fraud)           AS fraud
            FROM transactions
            {full_where}
            GROUP BY 1
            ORDER BY 1
        """, params)
        rows = [_serialize_row(r) for r in cur.fetchall()]
    return _ok(rows)


def _get_filters():
    conn = _get_conn()
    _ensure_schema(conn)
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT country FROM transactions WHERE country IS NOT NULL ORDER BY country")
        countries = [r[0] for r in cur.fetchall()]
        cur.execute("SELECT DISTINCT channel FROM transactions WHERE channel IS NOT NULL ORDER BY channel")
        channels = [r[0] for r in cur.fetchall()]
    return _ok({"countries": countries, "channels": channels})


def _list_transactions(query):
    conn = _get_conn()
    _ensure_schema(conn)

    limit  = min(int(query.get("limit", 20)), 100)
    offset = max(int(query.get("offset", 0)), 0)

    where, params = _build_where(query)

    sort_col, sort_dir = _sort_clause(query, _SORTABLE_TX, "processed_at")

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(f"SELECT COUNT(*) AS cnt FROM transactions {where}", params)
        total = cur.fetchone()["cnt"]

        cur.execute(
            f"""
            SELECT transaction_id, user_id, amount, currency, country, channel,
                   fraud_score, is_fraud, decision, processed_at
            FROM   transactions
            {where}
            ORDER  BY {sort_col} {sort_dir} NULLS LAST
            LIMIT  %s OFFSET %s
            """,
            params + [limit, offset],
        )
        rows = [_serialize_row(r) for r in cur.fetchall()]

    return _ok(rows, {"total": total, "limit": limit, "offset": offset,
                      "sort_by": sort_col, "sort_order": sort_dir.lower()})


def _get_transaction(tx_id):
    conn = _get_conn()
    _ensure_schema(conn)
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """
            SELECT transaction_id, user_id, amount, currency, country, channel,
                   fraud_score, is_fraud, decision, processed_at
            FROM   transactions WHERE transaction_id = %s
            """,
            (tx_id,),
        )
        row = cur.fetchone()
    if row is None:
        return _err(404, "NOT_FOUND", f"Transaction '{tx_id}' not found")
    return _ok(_serialize_row(row))


def _list_users(query):
    conn = _get_conn()
    _ensure_schema(conn)

    limit  = min(int(query.get("limit", 20)), 100)
    offset = max(int(query.get("offset", 0)), 0)

    # Users don't have direct country/channel fields; filter via subquery on transactions.
    sub_filters, sub_params = [], []
    if query.get("country"):
        sub_filters.append("country = %s"); sub_params.append(query["country"])
    if query.get("channel"):
        sub_filters.append("channel = %s"); sub_params.append(query["channel"])
    if query.get("from"):
        sub_filters.append("processed_at >= %s"); sub_params.append(query["from"])
    if query.get("to"):
        sub_filters.append("processed_at <= %s"); sub_params.append(query["to"])

    sub_where = ("WHERE " + " AND ".join(sub_filters)) if sub_filters else ""

    user_id_filter = ""
    user_params = list(sub_params)
    if query.get("user_id"):
        user_id_filter = "AND user_id = %s"
        user_params.append(query["user_id"])

    sort_col, sort_dir = _sort_clause(query, _SORTABLE_USERS, "fraud_count")

    count_sql = f"""
        SELECT COUNT(DISTINCT user_id) AS cnt
        FROM transactions {sub_where} {user_id_filter}
    """
    list_sql = f"""
        WITH stats AS (
            SELECT
                user_id,
                COUNT(*)                                            AS total_transactions,
                COUNT(*) FILTER (WHERE is_fraud)                   AS fraud_count,
                ROUND(AVG(fraud_score)::numeric, 4)                AS avg_fraud_score,
                MAX(processed_at)                                   AS last_seen,
                ROUND(
                    CAST(COUNT(*) FILTER (WHERE is_fraud) AS numeric)
                    / NULLIF(COUNT(*), 0) * 100, 1
                )                                                   AS fraud_rate_pct
            FROM transactions
            {sub_where} {user_id_filter}
            GROUP BY user_id
        )
        SELECT * FROM stats
        ORDER BY {sort_col} {sort_dir} NULLS LAST
        LIMIT %s OFFSET %s
    """

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(count_sql, user_params)
        total = cur.fetchone()["cnt"]
        cur.execute(list_sql, user_params + [limit, offset])
        rows = [_serialize_row(r) for r in cur.fetchall()]

    return _ok(rows, {"total": total, "limit": limit, "offset": offset,
                      "sort_by": sort_col, "sort_order": sort_dir.lower()})


def _get_user(user_id):
    conn = _get_conn()
    _ensure_schema(conn)

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """
            SELECT user_id,
                   COUNT(*)                                AS total_transactions,
                   COUNT(*) FILTER (WHERE is_fraud)        AS fraud_count,
                   ROUND(AVG(fraud_score)::numeric, 4)     AS avg_fraud_score,
                   MAX(processed_at)                       AS last_seen
            FROM transactions WHERE user_id = %s GROUP BY user_id
            """,
            (user_id,),
        )
        row = cur.fetchone()

    if row is None:
        return _err(404, "NOT_FOUND", f"User '{user_id}' not found")

    summary = _serialize_row(row)

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """
            SELECT transaction_id, amount, currency, country, channel,
                   fraud_score, is_fraud, decision, processed_at
            FROM   transactions WHERE user_id = %s ORDER BY processed_at DESC LIMIT 10
            """,
            (user_id,),
        )
        summary["recent_transactions"] = [_serialize_row(r) for r in cur.fetchall()]

    return _ok(summary)


# ── Router ────────────────────────────────────────────────────────────────────

def handler(event, context):
    path        = event.get("rawPath", "")
    query       = event.get("queryStringParameters") or {}
    path_params = event.get("pathParameters") or {}

    logger.info(json.dumps({"action": "api_request", "path": path, "query": query}))

    try:
        if path == "/health":
            return _health()
        if path == "/stats":
            return _get_stats(query)
        if path == "/stats/timeseries":
            return _get_stats_timeseries(query)
        if path == "/filters":
            return _get_filters()
        if path == "/transactions":
            return _list_transactions(query)
        if path_params.get("id") and path.startswith("/transactions/"):
            return _get_transaction(path_params["id"])
        if path == "/users":
            return _list_users(query)
        if path_params.get("id") and path.startswith("/users/"):
            return _get_user(path_params["id"])

        return _err(404, "NOT_FOUND", f"No route for {path}")

    except Exception as exc:
        logger.exception("unhandled error")
        return _err(500, "INTERNAL_ERROR", str(exc))
