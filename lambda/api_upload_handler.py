import base64
import json
import os
import uuid
from email import policy
from email.parser import BytesParser

import boto3

REGION = os.environ.get("AWS_REGION", "us-east-1")
RECEIPTS_BUCKET = os.environ["RECEIPTS_BUCKET"]
PROCESSOR_FUNCTION_NAME = os.environ.get("PROCESSOR_FUNCTION_NAME", "budgetsnap-receipt-processor")

s3 = boto3.client("s3", region_name=REGION)
lambda_client = boto3.client("lambda", region_name=REGION)


def _response(status: int, payload: dict):
    return {
        "statusCode": status,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "*",
            "Access-Control-Allow-Methods": "OPTIONS,POST",
        },
        "body": json.dumps(payload),
    }


def _extract_file_from_multipart(content_type: str, body_bytes: bytes):
    envelope = (
        f"Content-Type: {content_type}\r\n"
        "MIME-Version: 1.0\r\n"
        "\r\n"
    ).encode("utf-8") + body_bytes

    message = BytesParser(policy=policy.default).parsebytes(envelope)
    if not message.is_multipart():
        raise ValueError("Request is not multipart/form-data")

    for part in message.iter_parts():
        if part.get_content_disposition() != "form-data":
            continue
        filename = part.get_filename()
        if filename:
            return filename, part.get_payload(decode=True)

    raise ValueError("No file part found in multipart form")


def lambda_handler(event, context):
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return _response(200, {"ok": True})

    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    content_type = headers.get("content-type", "")
    if "multipart/form-data" not in content_type:
        return _response(400, {"message": "Expected multipart/form-data upload"})

    body = event.get("body", "")
    is_base64 = bool(event.get("isBase64Encoded"))
    body_bytes = base64.b64decode(body) if is_base64 else body.encode("utf-8")

    try:
        filename, file_bytes = _extract_file_from_multipart(content_type, body_bytes)
    except Exception as exc:
        return _response(400, {"message": f"Invalid upload body: {exc}"})

    safe_name = filename.replace(" ", "_")
    object_key = f"incoming/{uuid.uuid4()}-{safe_name}"

    s3.put_object(Bucket=RECEIPTS_BUCKET, Key=object_key, Body=file_bytes)

    s3_event = {
        "Records": [
            {
                "s3": {
                    "bucket": {"name": RECEIPTS_BUCKET},
                    "object": {"key": object_key},
                }
            }
        ]
    }

    invoke_resp = lambda_client.invoke(
        FunctionName=PROCESSOR_FUNCTION_NAME,
        InvocationType="RequestResponse",
        Payload=json.dumps(s3_event).encode("utf-8"),
    )

    payload_bytes = invoke_resp.get("Payload").read()
    result = json.loads(payload_bytes.decode("utf-8"))

    status_code = int(result.get("statusCode", 200))
    try:
        result_body = json.loads(result.get("body", "{}"))
    except Exception:
        result_body = {"raw": result.get("body")}

    result_body["uploaded_key"] = object_key
    result_body["bucket"] = RECEIPTS_BUCKET
    return _response(status_code, result_body)
