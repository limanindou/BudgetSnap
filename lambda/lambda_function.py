import json
import os
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

REGION = os.environ.get("AWS_REGION", "us-east-1")
EXPENSES_TABLE = os.environ.get("EXPENSES_TABLE", "expenses")
BUDGETS_TABLE = os.environ.get("BUDGETS_TABLE", "budgets")
BEDROCK_MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0")
DEFAULT_USER_ID = os.environ.get("DEFAULT_USER_ID", "demo-user")
USE_MOCK_BEDROCK = os.environ.get("USE_MOCK_BEDROCK", "false").lower() == "true"

bedrock = boto3.client("bedrock-runtime", region_name=REGION)
ddb = boto3.resource("dynamodb", region_name=REGION)
expenses_table = ddb.Table(EXPENSES_TABLE)
budgets_table = ddb.Table(BUDGETS_TABLE)


def _to_decimal(value: float) -> Decimal:
    return Decimal(str(round(float(value), 2)))


def _parse_s3_event(event):
    records = event.get("Records", [])
    if not records:
        raise ValueError("No S3 records in event")

    rec = records[0]
    bucket = rec["s3"]["bucket"]["name"]
    key = rec["s3"]["object"]["key"]
    return bucket, key


def _normalize_category(raw: str) -> str:
    allowed = {
        "groceries",
        "transport",
        "entertainment",
        "software",
        "travel",
        "utilities",
        "shopping",
        "healthcare",
        "other",
    }
    c = str(raw or "other").strip().lower()
    return c if c in allowed else "other"


def _mock_from_key(key: str):
    name = key.lower()
    if "transport" in name:
        return {
            "merchant": "City Transit Kiosk",
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "subtotal": 462.96,
            "tax": 37.04,
            "total": 500.00,
            "category": "transport",
            "advice": "You are over your transport budget. Reduce additional transport spending for the rest of the month.",
            "source": "mock_fallback",
        }
    if "entertainment" in name:
        return {
            "merchant": "Neon Arcade Center",
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "subtotal": 460.00,
            "tax": 40.00,
            "total": 500.00,
            "category": "entertainment",
            "advice": "You are over your entertainment budget. Plan low-cost activities for the rest of the month.",
            "source": "mock_fallback",
        }
    if "groceries" in name:
        return {
            "merchant": "Fresh Basket Market",
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "subtotal": 32.67,
            "tax": 2.78,
            "total": 35.45,
            "category": "groceries",
            "advice": "You are within grocery budget. Keep the next trip focused on essentials.",
            "source": "mock_fallback",
        }
    if "software" in name:
        return {
            "merchant": "Pixelflow Software LLC",
            "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "subtotal": 44.00,
            "tax": 3.74,
            "total": 47.74,
            "category": "software",
            "advice": "Software spending is within budget this month.",
            "source": "mock_fallback",
        }
    return {
        "merchant": "Home Goods Depot",
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "subtotal": 46.50,
        "tax": 3.84,
        "total": 50.34,
        "category": "other",
        "advice": "Spending remains within budget for this category.",
        "source": "mock_fallback",
    }


def _extract_with_bedrock_or_fallback(bucket: str, key: str):
    if USE_MOCK_BEDROCK:
        return _mock_from_key(key)

    s3 = boto3.client("s3", region_name=REGION)
    obj = s3.get_object(Bucket=bucket, Key=key)
    data = obj["Body"].read()

    ext = key.lower().split(".")[-1]
    if ext in {"jpg", "jpeg", "png", "webp", "gif"}:
        media = {
            "image": {
                "format": "jpeg" if ext == "jpg" else ext,
                "source": {"bytes": data},
            }
        }
    elif ext == "pdf":
        media = {
            "document": {
                "format": "pdf",
                "name": "receipt",
                "source": {"bytes": data},
            }
        }
    else:
        return _mock_from_key(key)

    prompt = (
        "Read the attached receipt and return JSON only with merchant, date, subtotal, tax, total, category, and one short advice sentence. "
        "Category must be one of groceries, transport, entertainment, software, travel, utilities, shopping, healthcare, other. "
        "No markdown. No extra text."
    )

    try:
        response = bedrock.converse(
            modelId=BEDROCK_MODEL_ID,
            messages=[
                {
                    "role": "user",
                    "content": [media, {"text": prompt}],
                }
            ],
            inferenceConfig={"maxTokens": 300, "temperature": 0.1},
        )
        text = response["output"]["message"]["content"][0]["text"]
        payload = json.loads(text)
        return {
            "merchant": payload.get("merchant", "Unknown Merchant"),
            "date": payload.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
            "subtotal": float(payload.get("subtotal", 0.0)),
            "tax": float(payload.get("tax", 0.0)),
            "total": float(payload.get("total", 0.0)),
            "category": _normalize_category(payload.get("category", "other")),
            "advice": payload.get("advice", ""),
            "source": "bedrock",
        }
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "")
        if code == "ThrottlingException":
            return _mock_from_key(key)
        raise
    except Exception:
        return _mock_from_key(key)


def _get_budget_limit(user_id: str, category: str, month: str) -> float:
    sk = f"BUDGET#{month}#{category}"
    item = budgets_table.get_item(Key={"pk": f"USER#{user_id}", "sk": sk}).get("Item")
    if not item:
        return 0.0
    return float(item.get("limitAmount", 0.0))


def _sum_spent(user_id: str, month: str, category: str) -> float:
    response = expenses_table.query(
        KeyConditionExpression=boto3.dynamodb.conditions.Key("pk").eq(f"USER#{user_id}")
            & boto3.dynamodb.conditions.Key("sk").begins_with("EXPENSE#")
    )
    spent = 0.0
    for it in response.get("Items", []):
        if it.get("month") == month and it.get("category") == category:
            spent += float(it.get("total", 0.0))
    return round(spent, 2)


def lambda_handler(event, context):
    bucket, key = _parse_s3_event(event)

    user_id = DEFAULT_USER_ID
    receipt = _extract_with_bedrock_or_fallback(bucket, key)

    category = _normalize_category(receipt.get("category", "other"))
    date_str = receipt.get("date") or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    month = date_str[:7]

    limit = _get_budget_limit(user_id, category, month)
    spent_before = _sum_spent(user_id, month, category)
    total = round(float(receipt.get("total", 0.0)), 2)
    spent_after = round(spent_before + total, 2)
    over_budget = spent_after > limit if limit > 0 else False
    over_by = round(max(spent_after - limit, 0.0), 2) if limit > 0 else 0.0

    if not receipt.get("advice"):
        if over_budget:
            advice = f"You are over your {category} budget by ${over_by:.2f}. Reduce spending in this category this month."
        else:
            advice = f"You are within your {category} budget at ${spent_after:.2f} of ${limit:.2f}."
    else:
        advice = receipt["advice"]

    expense_id = str(uuid.uuid4())
    item = {
        "pk": f"USER#{user_id}",
        "sk": f"EXPENSE#{date_str}#{expense_id}",
        "expenseId": expense_id,
        "month": month,
        "date": date_str,
        "merchant": receipt.get("merchant", "Unknown Merchant"),
        "category": category,
        "subtotal": _to_decimal(receipt.get("subtotal", 0.0)),
        "tax": _to_decimal(receipt.get("tax", 0.0)),
        "total": _to_decimal(total),
        "budgetLimit": _to_decimal(limit),
        "spentBefore": _to_decimal(spent_before),
        "spentAfter": _to_decimal(spent_after),
        "overBudget": over_budget,
        "overBy": _to_decimal(over_by),
        "advice": advice,
        "source": receipt.get("source", "unknown"),
        "receiptS3": f"s3://{bucket}/{key}",
        "createdAt": datetime.now(timezone.utc).isoformat(),
    }
    expenses_table.put_item(Item=item)

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "merchant": item["merchant"],
                "date": item["date"],
                "subtotal": float(item["subtotal"]),
                "tax": float(item["tax"]),
                "total": float(item["total"]),
                "category": item["category"],
                "budget_limit": float(item["budgetLimit"]),
                "spent_before": float(item["spentBefore"]),
                "spent_after": float(item["spentAfter"]),
                "over_budget": item["overBudget"],
                "over_by": float(item["overBy"]),
                "advice": item["advice"],
                "source": item["source"],
                "receipt_s3": item["receiptS3"],
            }
        ),
    }
