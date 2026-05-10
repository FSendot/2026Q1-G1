import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
}


def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path = event.get("rawPath", "")
    query = event.get("queryStringParameters") or {}

    logger.info(json.dumps({"action": "api_request", "method": method, "path": path}))

    if path == "/transactions":
        # TODO: query RDS — requires psycopg2 Lambda layer + real implementation
        return {
            "statusCode": 200,
            "headers": HEADERS,
            "body": json.dumps({
                "transactions": [],
                "count": 0,
                "message": "placeholder — connect Lambda to RDS with psycopg2 layer",
            }),
        }

    return {
        "statusCode": 404,
        "headers": HEADERS,
        "body": json.dumps({"error": "not found"}),
    }
