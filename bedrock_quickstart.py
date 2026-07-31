import argparse
import json
import os
import pathlib
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError
from botocore.exceptions import NoCredentialsError

PROMPT = (
    "Read the attached receipt and return JSON only with merchant, date, subtotal, tax, total, "
    "category, and one short advice sentence. "
    "Category must be one of groceries, transport, entertainment, software, travel, utilities, "
    "shopping, healthcare, other. No markdown. No extra text."
)


def detect_media_block(file_path: pathlib.Path, content_bytes: bytes) -> dict:
    ext = file_path.suffix.lower()

    if ext in {".jpg", ".jpeg", ".png", ".webp", ".gif"}:
        image_format = "jpeg" if ext == ".jpg" else ext.lstrip(".")
        return {
            "image": {
                "format": image_format,
                "source": {"bytes": content_bytes},
            }
        }

    if ext == ".pdf":
        return {
            "document": {
                "format": "pdf",
                "name": file_path.stem,
                "source": {"bytes": content_bytes},
            }
        }

    raise ValueError(f"Unsupported file extension: {ext}")


def build_mock_output(file_path: pathlib.Path) -> dict:
    name = file_path.name.lower()

    if "transport" in name:
        category = "transport"
        subtotal = 462.96
        tax = 37.04
        total = 500.00
    elif "entertainment" in name:
        category = "entertainment"
        subtotal = 460.00
        tax = 40.00
        total = 500.00
    elif "groceries" in name:
        category = "groceries"
        subtotal = 32.67
        tax = 2.78
        total = 35.45
    elif "software" in name:
        category = "software"
        subtotal = 44.00
        tax = 3.74
        total = 47.74
    else:
        category = "other"
        subtotal = 46.50
        tax = 3.84
        total = 50.34

    budget_limit = 100.0
    spent_before = 0.0
    spent_after = round(spent_before + total, 2)
    over_budget = spent_after > budget_limit
    over_by = round(max(spent_after - budget_limit, 0.0), 2)

    if over_budget:
        advice = f"You are over your {category} budget by ${over_by:.2f}; reduce spending in this category for the rest of the month."
    else:
        advice = f"You are within your {category} budget; current spend is ${spent_after:.2f} of ${budget_limit:.2f}."

    return {
        "merchant": "Mock Merchant",
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "subtotal": subtotal,
        "tax": tax,
        "total": total,
        "category": category,
        "budget_limit": budget_limit,
        "spent_before": spent_before,
        "spent_after": spent_after,
        "over_budget": over_budget,
        "over_by": over_by,
        "advice": advice,
        "source": "mock_fallback",
    }


def run(
    model_id: str,
    file_path: str,
    region: str,
    max_tokens: int,
    temperature: float,
    mock_on_throttle: bool,
) -> None:
    path = pathlib.Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"File not found: {file_path}")

    with path.open("rb") as f:
        content_bytes = f.read()

    media_block = detect_media_block(path, content_bytes)

    client = boto3.client("bedrock-runtime", region_name=region)

    try:
        response = client.converse(
            modelId=model_id,
            messages=[
                {
                    "role": "user",
                    "content": [
                        media_block,
                        {"text": PROMPT},
                    ],
                }
            ],
            inferenceConfig={
                "maxTokens": max_tokens,
                "temperature": temperature,
            },
        )
    except NoCredentialsError:
        print("No AWS credentials were found for boto3.")
        print("Run one of these in PowerShell, then rerun this script:")
        print("  aws login")
        print("  or")
        print("  aws configure")
        print("Then verify with: aws sts get-caller-identity")
        return
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "Unknown")
        message = e.response.get("Error", {}).get("Message", str(e))

        if code == "ThrottlingException":
            print("Bedrock throttling hit:")
            print(message)
            if mock_on_throttle:
                mock = build_mock_output(path)
                print("\nUsing mock fallback output:\n")
                print(json.dumps(mock, indent=2))
            else:
                print("\nTip: rerun with --mock-on-throttle to keep testing while quota resets.")
            return

        raise

    text = response["output"]["message"]["content"][0]["text"]
    print("Raw model output:\n")
    print(text)

    # Optional parse check so you know if output is valid JSON.
    try:
        parsed = json.loads(text)
        print("\nParsed JSON keys:", list(parsed.keys()))
    except json.JSONDecodeError:
        print("\nOutput was not strict JSON. Tighten prompt or lower max tokens.")


def main() -> None:
    parser = argparse.ArgumentParser(description="BudgetSnap Bedrock quickstart")
    parser.add_argument(
        "--model-id",
        default=os.getenv("BEDROCK_MODEL_ID", "amazon.nova-lite-v1:0"),
        help="Bedrock model ID (default: amazon.nova-lite-v1:0)",
    )
    parser.add_argument(
        "--file",
        default="sample-receipts/receipt_transport_02.png",
        help="Path to receipt image/pdf",
    )
    parser.add_argument(
        "--region",
        default=os.getenv("AWS_REGION", "us-east-1"),
        help="AWS region (default: us-east-1)",
    )
    parser.add_argument("--max-tokens", type=int, default=300)
    parser.add_argument("--temperature", type=float, default=0.1)
    parser.add_argument(
        "--mock-on-throttle",
        action="store_true",
        help="Return deterministic mock output when Bedrock throttles.",
    )
    args = parser.parse_args()

    run(
        model_id=args.model_id,
        file_path=args.file,
        region=args.region,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        mock_on_throttle=args.mock_on_throttle,
    )


if __name__ == "__main__":
    main()
