# BudgetSnap

BudgetSnap is a lightweight receipt-to-budget demo built for AWS serverless services. It lets a user upload a receipt image or PDF, extracts key fields, stores the expense, and checks the result against a category budget.


## What's Included

- `index.html`: single-page frontend
- `lambda/lambda_function.py`: receipt processor Lambda
- `lambda/api_upload_handler.py`: browser upload Lambda
- `deploy/`: static website config and policy templates
- `dynamodb-seed/`: sample budget seed data
- `bedrock_quickstart.py`: local Bedrock test script

## Architecture

1. The browser uploads a receipt to API Gateway.
2. API Gateway invokes the upload Lambda.
3. The upload Lambda stores the file in S3.
4. The processor Lambda reads the uploaded object.
5. The processor extracts receipt data with Amazon Bedrock or a mock fallback.
6. The processor reads and writes budget data in DynamoDB.
7. The API returns a normalized budget result to the frontend.

## Prerequisites

- AWS account
- AWS CLI configured
- Python 3.11+
- An S3 bucket for uploaded receipts
- An S3 bucket for static website hosting
- Two DynamoDB tables for budgets and expenses
- Two Lambda functions
- One HTTP API in API Gateway

## Configure the Frontend

Open `index.html` and set the API URL in `window.BUDGETSNAP_CONFIG`:

```html
window.BUDGETSNAP_CONFIG = {
  apiUrl: "https://your-api-id.execute-api.us-east-1.amazonaws.com/upload"
};
```

If `apiUrl` is empty, the app stays in demo mode.

## Lambda Environment Variables

### Receipt processor Lambda

- `AWS_REGION=us-east-1`
- `EXPENSES_TABLE=expenses`
- `BUDGETS_TABLE=budgets`
- `BEDROCK_MODEL_ID=amazon.nova-lite-v1:0`
- `DEFAULT_USER_ID=demo-user`
- `USE_MOCK_BEDROCK=true` or `false`

### Upload Lambda

- `AWS_REGION=us-east-1`
- `RECEIPTS_BUCKET=<your-receipts-bucket>`
- `PROCESSOR_FUNCTION_NAME=<your-processor-function-name>`

## Deployment Notes

Template files in this repo contain placeholders and must be updated before deployment:

- `deploy/bucket-policy.json`
- `lambda/invoke-processor-policy.json`
- `lambda/s3-notification.json`

Replace values such as:

- `<static-site-bucket>`
- `<region>`
- `<account-id>`
- `<processor-function-name>`

## Local Testing

To test the Bedrock extraction flow locally:

```powershell
python bedrock_quickstart.py --file sample-receipts/receipt_transport_02.png --mock-on-throttle
```
