from __future__ import annotations

import json
import os
from datetime import date, datetime, timezone
from decimal import Decimal
from urllib.parse import parse_qs

from wsgiref.simple_server import make_server

try:
    import psycopg2
    from psycopg2.extras import RealDictCursor

    _HAVE_PSYCOPG2 = True
except ImportError:
    _HAVE_PSYCOPG2 = False

# ---------- RDS: si DB_HOST queda vacío, se usa el mock. ----------
DB_HOST = os.environ.get("DB_HOST", "")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "")
DB_USER = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_SSLMODE = os.environ.get("DB_SSLMODE", "require")

# Datos de ejemplo si RDS no está configurado
_MOCK_STATS = {
    "total": 12847,
    "fraud": 626,
    "allowed": 11200,
    "challenged": 1021,
    "blocked": 626,
    "fraud_rate": 0.0487,
    "avg_fraud_score": 0.41,
}

_MOCK_TRANSACTIONS = [
    {
        "transaction_id": "tx_demo_001",
        "user_id": "u_100",
        "amount": 15000.0,
        "currency": "ARS",
        "country": "BR",
        "channel": "web",
        "fraud_score": 0.85,
        "decision": "block",
        "processed_at": "2026-04-03T10:22:00.123Z",
    },
    {
        "transaction_id": "tx_demo_002",
        "user_id": "u_101",
        "amount": 3200.0,
        "currency": "ARS",
        "country": "AR",
        "channel": "mobile",
        "fraud_score": 0.35,
        "decision": "allow",
        "processed_at": "2026-04-03T10:25:11.000Z",
    },
    {
        "transaction_id": "tx_demo_003",
        "user_id": "u_102",
        "amount": 8900.0,
        "currency": "ARS",
        "country": "UY",
        "channel": "atm",
        "fraud_score": 0.55,
        "decision": "challenge",
        "processed_at": "2026-04-03T10:28:44.500Z",
    },
]

_CORS_HEADERS = [
    ("Access-Control-Allow-Origin", "*"),
    ("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"),
    ("Access-Control-Allow-Headers", "Content-Type, Accept, Authorization, X-Cognito-Access-Token"),
]

_SQL_STATS = """
SELECT
  COUNT(*)::bigint AS total_transactions,
  COUNT(*) FILTER (
    WHERE is_fraud = FALSE OR LOWER(TRIM(decision)) IN ('allow', 'allowed')
  )::bigint AS allowed,
  COUNT(*) FILTER (WHERE LOWER(TRIM(decision)) = 'challenge')::bigint AS challenge,
  COUNT(*) FILTER (
    WHERE is_fraud = TRUE OR LOWER(TRIM(decision)) IN ('block', 'blocked')
  )::bigint AS blocked
FROM transactions;
"""

_SQL_TRANSACTIONS = """
SELECT
  transaction_id,
  user_id,
  amount,
  currency,
  country,
  CASE
    WHEN fraud_score IS NULL THEN NULL
    ELSE ROUND((fraud_score * 100)::numeric, 0)
  END AS score,
  CASE
    WHEN LOWER(TRIM(decision)) = 'allow' THEN 'allowed'
    WHEN LOWER(TRIM(decision)) = 'block' THEN 'blocked'
    ELSE decision
  END AS decision,
  processed_at
FROM transactions
ORDER BY processed_at DESC NULLS LAST, transaction_id DESC
LIMIT %s;
"""


def _db_env_configured() -> bool:
    return bool(DB_HOST and DB_NAME and DB_USER)


def _connect_rds():
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        sslmode=DB_SSLMODE,
    )


def _json_value(v):
    if v is None:
        return None
    if isinstance(v, datetime):
        if v.tzinfo is None:
            v = v.replace(tzinfo=timezone.utc)
        return v.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    if isinstance(v, date):
        return v.isoformat()
    if isinstance(v, Decimal):
        return float(v)
    return v


def _row_to_api_dict(row: dict) -> dict:
    return {k: _json_value(v) for k, v in row.items()}


def _fetch_stats_from_db():
    with _connect_rds() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(_SQL_STATS)
            row = cur.fetchone()
    if not row:
        return {
            "total_transactions": 0,
            "allowed": 0,
            "challenge": 0,
            "blocked": 0,
        }
    return {
        "total_transactions": int(row["total_transactions"]),
        "allowed": int(row["allowed"]),
        "challenge": int(row["challenge"]),
        "blocked": int(row["blocked"]),
    }


def _fetch_transactions_from_db(limit: int):
    with _connect_rds() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(_SQL_TRANSACTIONS, (limit,))
            rows = cur.fetchall()
    return [_row_to_api_dict(dict(r)) for r in rows]


def _json_response(
    start_response, status: str, obj: object
) -> list[bytes]:
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    headers = [
        ("Content-Type", "application/json; charset=utf-8"),
        ("Content-Length", str(len(body))),
    ] + _CORS_HEADERS
    start_response(status, headers)
    return [body]


def _ok(data, meta=None):
    body = {"data": data}
    if meta is not None:
        body["meta"] = meta
    return body


def _mock_user_rows():
    grouped = {}
    for tx in _MOCK_TRANSACTIONS:
        user = grouped.setdefault(
            tx["user_id"],
            {
                "user_id": tx["user_id"],
                "total_transactions": 0,
                "fraud_count": 0,
                "avg_fraud_score": 0.0,
                "last_seen": tx["processed_at"],
            },
        )
        user["total_transactions"] += 1
        user["fraud_count"] += 1 if tx["decision"] == "block" else 0
        user["avg_fraud_score"] += tx["fraud_score"]
        user["last_seen"] = max(user["last_seen"], tx["processed_at"])
    for user in grouped.values():
        user["avg_fraud_score"] = user["avg_fraud_score"] / max(user["total_transactions"], 1)
        user["fraud_rate_pct"] = round(user["fraud_count"] / max(user["total_transactions"], 1) * 100, 1)
    return list(grouped.values())


def application(environ, start_response):
    method = environ.get("REQUEST_METHOD", "GET")
    path = environ.get("PATH_INFO") or "/"
    query = environ.get("QUERY_STRING") or ""

    if method == "OPTIONS":
        start_response("204 No Content", _CORS_HEADERS)
        return [b""]

    if method not in ("GET", "POST", "PUT", "DELETE"):
        return _json_response(
            start_response,
            "405 Method Not Allowed",
            {"error": "method_not_allowed"},
        )

    # "/" responde OK: muchos health checks (ALB/ELB) usan GET / por defecto.
    if path in ("/", "/health"):
        return _json_response(start_response, "200 OK", _ok({"status": "ok"}))

    if path == "/dashboard/me":
        return _json_response(
            start_response,
            "200 OK",
            _ok({
                "email": "local@example.test",
                "role": "admin",
                "status": "active",
                "can_manage_invites": True,
                "can_change_password": False,
                "auth_provider": "local-bypass",
                "is_bootstrap_admin": True,
            }),
        )

    if path == "/dashboard/invites":
        if method == "POST":
            return _json_response(
                start_response,
                "200 OK",
                _ok({
                    "id": "local-invite",
                    "email": "local-invite@example.test",
                    "role": "viewer",
                    "status": "pending",
                    "is_bootstrap_admin": False,
                }),
            )
        return _json_response(start_response, "200 OK", _ok([], {"total": 0}))

    if path.startswith("/dashboard/invites/") and method == "DELETE":
        return _json_response(start_response, "200 OK", _ok({"status": "disabled"}))

    if path == "/filters":
        return _json_response(
            start_response,
            "200 OK",
            _ok({
                "countries": sorted({tx["country"] for tx in _MOCK_TRANSACTIONS}),
                "channels": sorted({tx["channel"] for tx in _MOCK_TRANSACTIONS}),
            }),
        )

    if path == "/stats/timeseries":
        return _json_response(start_response, "200 OK", _ok([]))

    if path in ("/stats", "/api/stats"):
        if _db_env_configured():
            if not _HAVE_PSYCOPG2:
                return _json_response(
                    start_response,
                    "503 Service Unavailable",
                    {
                        "error": "psycopg2_missing",
                        "detail": "Instalá python3-psycopg2 con el gestor de paquetes del SO.",
                    },
                )
            try:
                stats = _fetch_stats_from_db()
            except Exception as e:
                return _json_response(
                    start_response,
                    "503 Service Unavailable",
                    {"error": "database_error", "detail": str(e)},
                )
            return _json_response(start_response, "200 OK", _ok({
                "total": stats["total_transactions"],
                "fraud": stats["blocked"],
                "allowed": stats["allowed"],
                "blocked": stats["blocked"],
                "challenged": stats["challenge"],
                "fraud_rate": round(stats["blocked"] / max(stats["total_transactions"], 1), 4),
                "avg_fraud_score": None,
            }))
        return _json_response(start_response, "200 OK", _ok(_MOCK_STATS))

    if path in ("/transactions", "/api/transactions"):
        qs = parse_qs(query)
        raw_limit = (qs.get("limit") or ["20"])[0]
        try:
            limit = int(raw_limit)
        except ValueError:
            limit = 20
        limit = max(1, min(limit, 100))
        if _db_env_configured():
            if not _HAVE_PSYCOPG2:
                return _json_response(
                    start_response,
                    "503 Service Unavailable",
                    {
                        "error": "psycopg2_missing",
                        "detail": "Instalá python3-psycopg2 con el gestor de paquetes del SO.",
                    },
                )
            try:
                items = _fetch_transactions_from_db(limit)
            except Exception as e:
                return _json_response(
                    start_response,
                    "503 Service Unavailable",
                    {"error": "database_error", "detail": str(e)},
                )
            return _json_response(start_response, "200 OK", _ok(items, {"total": len(items), "limit": limit, "offset": 0}))
        return _json_response(
            start_response,
            "200 OK",
            _ok(_MOCK_TRANSACTIONS[:limit], {"total": len(_MOCK_TRANSACTIONS), "limit": limit, "offset": 0}),
        )

    if path == "/users":
        rows = _mock_user_rows()
        return _json_response(start_response, "200 OK", _ok(rows, {"total": len(rows), "limit": len(rows), "offset": 0}))

    if path in ("/version", "/api/version"):
        return _json_response(
            start_response,
            "200 OK",
            {
                "service": "fraud-dashboard-api",
                "version": "1.0.0",
                "time": datetime.now(timezone.utc).isoformat(),
            },
        )

    return _json_response(
        start_response,
        "404 Not Found",
        {"error": "not_found", "path": path},
    )


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5000"))
    host = os.environ.get("HOST", "0.0.0.0")
    with make_server(host, port, application) as httpd:
        print(f"Serving on http://{host}:{port}")
        httpd.serve_forever()
