[CmdletBinding()]
param(
  [string]$ProjectName = "budgetsnap",
  [string]$Region = "us-east-1",
  [string]$DefaultUserId = "demo-user",
  [switch]$UseRealBedrock
)

$ErrorActionPreference = "Stop"

function Invoke-AwsCli {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,
    [switch]$AllowFailure
  )

  $output = & aws @Arguments 2>&1
  if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
    throw "AWS CLI command failed:`naws $($Arguments -join ' ')`n`n$output"
  }

  return ($output | Out-String).Trim()
}

function Test-AwsCli {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  & aws @Arguments *> $null
  return $LASTEXITCODE -eq 0
}

function New-TempJsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    $Object
  )

  $Object | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function Ensure-Bucket {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BucketName
  )

  if (Test-AwsCli @("s3api", "head-bucket", "--bucket", $BucketName)) {
    return
  }

  if ($Region -eq "us-east-1") {
    Invoke-AwsCli -Arguments @("s3api", "create-bucket", "--bucket", $BucketName, "--region", $Region) | Out-Null
  }
  else {
    Invoke-AwsCli -Arguments @(
      "s3api", "create-bucket",
      "--bucket", $BucketName,
      "--region", $Region,
      "--create-bucket-configuration", "LocationConstraint=$Region"
    ) | Out-Null
  }
}

function Ensure-DynamoTable {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TableName
  )

  if (Test-AwsCli @("dynamodb", "describe-table", "--table-name", $TableName, "--region", $Region)) {
    return
  }

  Invoke-AwsCli -Arguments @(
    "dynamodb", "create-table",
    "--table-name", $TableName,
    "--attribute-definitions", "AttributeName=pk,AttributeType=S", "AttributeName=sk,AttributeType=S",
    "--key-schema", "AttributeName=pk,KeyType=HASH", "AttributeName=sk,KeyType=RANGE",
    "--billing-mode", "PAY_PER_REQUEST",
    "--region", $Region
  ) | Out-Null

  Invoke-AwsCli -Arguments @("dynamodb", "wait", "table-exists", "--table-name", $TableName, "--region", $Region) | Out-Null
}

function Ensure-Role {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RoleName,
    [Parameter(Mandatory = $true)]
    [string]$TrustPolicyPath,
    [Parameter(Mandatory = $true)]
    [string]$InlinePolicyPath
  )

  if (-not (Test-AwsCli @("iam", "get-role", "--role-name", $RoleName))) {
    Invoke-AwsCli -Arguments @(
      "iam", "create-role",
      "--role-name", $RoleName,
      "--assume-role-policy-document", "file://$TrustPolicyPath"
    ) | Out-Null
  }

  Invoke-AwsCli -Arguments @(
    "iam", "attach-role-policy",
    "--role-name", $RoleName,
    "--policy-arn", "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ) -AllowFailure | Out-Null

  Invoke-AwsCli -Arguments @(
    "iam", "put-role-policy",
    "--role-name", $RoleName,
    "--policy-name", "$ProjectName-inline-policy",
    "--policy-document", "file://$InlinePolicyPath"
  ) | Out-Null

  Start-Sleep -Seconds 10
  return Invoke-AwsCli -Arguments @("iam", "get-role", "--role-name", $RoleName, "--query", "Role.Arn", "--output", "text")
}

function Publish-LambdaZip {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile,
    [Parameter(Mandatory = $true)]
    [string]$ZipPath
  )

  if (Test-Path $ZipPath) {
    Remove-Item $ZipPath -Force
  }

  Compress-Archive -Path $SourceFile -DestinationPath $ZipPath -Force
}

function Ensure-LambdaFunction {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionName,
    [Parameter(Mandatory = $true)]
    [string]$RoleArn,
    [Parameter(Mandatory = $true)]
    [string]$Handler,
    [Parameter(Mandatory = $true)]
    [string]$ZipPath,
    [Parameter(Mandatory = $true)]
    [hashtable]$EnvironmentVariables
  )

  $envJson = (@{ Variables = $EnvironmentVariables } | ConvertTo-Json -Compress)

  if (Test-AwsCli @("lambda", "get-function", "--function-name", $FunctionName, "--region", $Region)) {
    Invoke-AwsCli -Arguments @(
      "lambda", "update-function-code",
      "--function-name", $FunctionName,
      "--zip-file", "fileb://$ZipPath",
      "--region", $Region
    ) | Out-Null

    Invoke-AwsCli -Arguments @(
      "lambda", "update-function-configuration",
      "--function-name", $FunctionName,
      "--runtime", "python3.12",
      "--handler", $Handler,
      "--role", $RoleArn,
      "--timeout", "30",
      "--memory-size", "512",
      "--environment", $envJson,
      "--region", $Region
    ) | Out-Null
  }
  else {
    Invoke-AwsCli -Arguments @(
      "lambda", "create-function",
      "--function-name", $FunctionName,
      "--runtime", "python3.12",
      "--handler", $Handler,
      "--role", $RoleArn,
      "--zip-file", "fileb://$ZipPath",
      "--timeout", "30",
      "--memory-size", "512",
      "--environment", $envJson,
      "--region", $Region
    ) | Out-Null
  }

  Invoke-AwsCli -Arguments @("lambda", "wait", "function-updated-v2", "--function-name", $FunctionName, "--region", $Region) -AllowFailure | Out-Null
  return Invoke-AwsCli -Arguments @("lambda", "get-function", "--function-name", $FunctionName, "--query", "Configuration.FunctionArn", "--output", "text", "--region", $Region)
}

function Ensure-LambdaPermission {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionName,
    [Parameter(Mandatory = $true)]
    [string]$StatementId,
    [Parameter(Mandatory = $true)]
    [string]$Principal,
    [Parameter(Mandatory = $true)]
    [string]$Action,
    [string]$SourceArn
  )

  $args = @(
    "lambda", "add-permission",
    "--function-name", $FunctionName,
    "--statement-id", $StatementId,
    "--principal", $Principal,
    "--action", $Action,
    "--region", $Region
  )

  if ($SourceArn) {
    $args += @("--source-arn", $SourceArn)
  }

  Invoke-AwsCli -Arguments $args -AllowFailure | Out-Null
}

function Ensure-HttpApi {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ApiName,
    [Parameter(Mandatory = $true)]
    [string]$LambdaArn,
    [Parameter(Mandatory = $true)]
    [string]$UploadFunctionName,
    [Parameter(Mandatory = $true)]
    [string]$AccountId
  )

  $apiId = Invoke-AwsCli -Arguments @(
    "apigatewayv2", "get-apis",
    "--region", $Region,
    "--query", "Items[?Name=='$ApiName'].ApiId | [0]",
    "--output", "text"
  )

  if (-not $apiId -or $apiId -eq "None") {
    $apiId = Invoke-AwsCli -Arguments @(
      "apigatewayv2", "create-api",
      "--name", $ApiName,
      "--protocol-type", "HTTP",
      "--cors-configuration", "AllowOrigins=*,AllowMethods=OPTIONS,POST,AllowHeaders=*",
      "--query", "ApiId",
      "--output", "text",
      "--region", $Region
    )
  }

  $integrationId = Invoke-AwsCli -Arguments @(
    "apigatewayv2", "get-integrations",
    "--api-id", $apiId,
    "--region", $Region,
    "--query", "Items[0].IntegrationId",
    "--output", "text"
  )

  if (-not $integrationId -or $integrationId -eq "None") {
    $integrationUri = "arn:aws:apigateway:$Region:lambda:path/2015-03-31/functions/$LambdaArn/invocations"
    $integrationId = Invoke-AwsCli -Arguments @(
      "apigatewayv2", "create-integration",
      "--api-id", $apiId,
      "--integration-type", "AWS_PROXY",
      "--integration-uri", $integrationUri,
      "--payload-format-version", "2.0",
      "--timeout-in-millis", "30000",
      "--query", "IntegrationId",
      "--output", "text",
      "--region", $Region
    )
  }

  $routeId = Invoke-AwsCli -Arguments @(
    "apigatewayv2", "get-routes",
    "--api-id", $apiId,
    "--region", $Region,
    "--query", "Items[?RouteKey=='POST /upload'].RouteId | [0]",
    "--output", "text"
  )

  if (-not $routeId -or $routeId -eq "None") {
    Invoke-AwsCli -Arguments @(
      "apigatewayv2", "create-route",
      "--api-id", $apiId,
      "--route-key", "POST /upload",
      "--target", "integrations/$integrationId",
      "--region", $Region
    ) | Out-Null
  }

  $stage = Invoke-AwsCli -Arguments @(
    "apigatewayv2", "get-stages",
    "--api-id", $apiId,
    "--region", $Region,
    "--query", "Items[?StageName=='$default'].StageName | [0]",
    "--output", "text"
  )

  if (-not $stage -or $stage -eq "None") {
    Invoke-AwsCli -Arguments @(
      "apigatewayv2", "create-stage",
      "--api-id", $apiId,
      "--stage-name", '$default',
      "--auto-deploy",
      "--region", $Region
    ) | Out-Null
  }

  Ensure-LambdaPermission -FunctionName $UploadFunctionName -StatementId "$ProjectName-api-gateway" -Principal "apigateway.amazonaws.com" -Action "lambda:InvokeFunction" -SourceArn "arn:aws:execute-api:$Region:$AccountId:$apiId/*/POST/upload"

  return "https://$apiId.execute-api.$Region.amazonaws.com/upload"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$accountId = Invoke-AwsCli -Arguments @("sts", "get-caller-identity", "--query", "Account", "--output", "text", "--region", $Region)

$normalizedProject = $ProjectName.ToLower()
$appBucket = "$normalizedProject-app-$accountId-$Region"
$receiptsBucket = "$normalizedProject-uploads-$accountId-$Region"
$expensesTable = "$normalizedProject-expenses"
$budgetsTable = "$normalizedProject-budgets"
$roleName = "$normalizedProject-lambda-role"
$processorFunctionName = "$normalizedProject-receipt-processor"
$uploadFunctionName = "$normalizedProject-api-upload"
$apiName = "$normalizedProject-http-api"

$workDir = Join-Path $env:TEMP ("budgetsnap-deploy-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workDir | Out-Null

try {
  $trustPolicyPath = Join-Path $workDir "trust-policy.json"
  $inlinePolicyPath = Join-Path $workDir "inline-policy.json"
  $processorZip = Join-Path $workDir "lambda-package.zip"
  $uploadZip = Join-Path $workDir "api-upload-package.zip"
  $bucketPolicyPath = Join-Path $workDir "bucket-policy.json"
  $tempIndexPath = Join-Path $workDir "index.html"

  New-TempJsonFile -Path $trustPolicyPath -Object @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Effect = "Allow"
        Principal = @{ Service = "lambda.amazonaws.com" }
        Action = "sts:AssumeRole"
      }
    )
  }

  New-TempJsonFile -Path $inlinePolicyPath -Object @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Effect = "Allow"
        Action = @(
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query"
        )
        Resource = @(
          "arn:aws:dynamodb:$Region:$accountId:table/$expensesTable",
          "arn:aws:dynamodb:$Region:$accountId:table/$budgetsTable"
        )
      },
      @{
        Effect = "Allow"
        Action = @(
          "s3:GetObject",
          "s3:PutObject"
        )
        Resource = @(
          "arn:aws:s3:::$receiptsBucket/*",
          "arn:aws:s3:::$appBucket/*"
        )
      },
      @{
        Effect = "Allow"
        Action = @("s3:ListBucket")
        Resource = @(
          "arn:aws:s3:::$receiptsBucket",
          "arn:aws:s3:::$appBucket"
        )
      },
      @{
        Effect = "Allow"
        Action = @("lambda:InvokeFunction")
        Resource = "arn:aws:lambda:$Region:$accountId:function:$processorFunctionName"
      },
      @{
        Effect = "Allow"
        Action = @(
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        )
        Resource = "*"
      }
    )
  }

  Write-Host "Creating or reusing infrastructure..."

  Ensure-Bucket -BucketName $appBucket
  Ensure-Bucket -BucketName $receiptsBucket
  Ensure-DynamoTable -TableName $expensesTable
  Ensure-DynamoTable -TableName $budgetsTable

  $roleArn = Ensure-Role -RoleName $roleName -TrustPolicyPath $trustPolicyPath -InlinePolicyPath $inlinePolicyPath

  Publish-LambdaZip -SourceFile (Join-Path $repoRoot "lambda\lambda_function.py") -ZipPath $processorZip
  Publish-LambdaZip -SourceFile (Join-Path $repoRoot "lambda\api_upload_handler.py") -ZipPath $uploadZip

  $processorArn = Ensure-LambdaFunction -FunctionName $processorFunctionName -RoleArn $roleArn -Handler "lambda_function.lambda_handler" -ZipPath $processorZip -EnvironmentVariables @{
    AWS_REGION = $Region
    EXPENSES_TABLE = $expensesTable
    BUDGETS_TABLE = $budgetsTable
    BEDROCK_MODEL_ID = "amazon.nova-lite-v1:0"
    DEFAULT_USER_ID = $DefaultUserId
    USE_MOCK_BEDROCK = $(if ($UseRealBedrock) { "false" } else { "true" })
  }

  $uploadArn = Ensure-LambdaFunction -FunctionName $uploadFunctionName -RoleArn $roleArn -Handler "api_upload_handler.lambda_handler" -ZipPath $uploadZip -EnvironmentVariables @{
    AWS_REGION = $Region
    RECEIPTS_BUCKET = $receiptsBucket
    PROCESSOR_FUNCTION_NAME = $processorFunctionName
  }

  Ensure-LambdaPermission -FunctionName $processorFunctionName -StatementId "$ProjectName-s3-trigger" -Principal "s3.amazonaws.com" -Action "lambda:InvokeFunction" -SourceArn "arn:aws:s3:::$receiptsBucket"

  $apiUrl = Ensure-HttpApi -ApiName $apiName -LambdaArn $uploadArn -UploadFunctionName $uploadFunctionName -AccountId $accountId

  $notificationConfig = @{
    LambdaFunctionConfigurations = @(
      @{
        Id = "$ProjectName-upload-trigger"
        LambdaFunctionArn = $processorArn
        Events = @("s3:ObjectCreated:*")
      }
    )
  } | ConvertTo-Json -Depth 10 -Compress

  Invoke-AwsCli -Arguments @(
    "s3api", "put-bucket-notification-configuration",
    "--bucket", $receiptsBucket,
    "--notification-configuration", $notificationConfig,
    "--region", $Region
  ) | Out-Null

  $month = Get-Date -Format "yyyy-MM"
  foreach ($category in @("groceries", "transport", "entertainment", "other")) {
    $seedItemPath = Join-Path $workDir ("seed-" + $category + ".json")
    New-TempJsonFile -Path $seedItemPath -Object @{
      pk = @{ S = "USER#$DefaultUserId" }
      sk = @{ S = "BUDGET#$month#$category" }
      limitAmount = @{ N = "100" }
    }

    Invoke-AwsCli -Arguments @(
      "dynamodb", "put-item",
      "--table-name", $budgetsTable,
      "--item", "file://$seedItemPath",
      "--region", $Region
    ) | Out-Null
  }

  New-TempJsonFile -Path $bucketPolicyPath -Object @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "PublicReadGetObject"
        Effect = "Allow"
        Principal = "*"
        Action = "s3:GetObject"
        Resource = "arn:aws:s3:::$appBucket/*"
      }
    )
  }

  Invoke-AwsCli -Arguments @("s3api", "delete-public-access-block", "--bucket", $appBucket, "--region", $Region) -AllowFailure | Out-Null
  Invoke-AwsCli -Arguments @("s3api", "put-bucket-website", "--bucket", $appBucket, "--website-configuration", "file://$PSScriptRoot\website-config.json", "--region", $Region) | Out-Null
  Invoke-AwsCli -Arguments @("s3api", "put-bucket-policy", "--bucket", $appBucket, "--policy", "file://$bucketPolicyPath", "--region", $Region) | Out-Null

  $indexTemplate = Get-Content (Join-Path $repoRoot "index.html") -Raw
  $deployedIndex = $indexTemplate -replace 'apiUrl: ""', ('apiUrl: "' + $apiUrl + '"')
  Set-Content -Path $tempIndexPath -Value $deployedIndex -Encoding UTF8

  Invoke-AwsCli -Arguments @("s3", "cp", $tempIndexPath, "s3://$appBucket/index.html", "--region", $Region) | Out-Null

  $siteUrl = "http://$appBucket.s3-website-$Region.amazonaws.com"

  Write-Host ""
  Write-Host "Deployment complete."
  Write-Host "App URL: $siteUrl"
  Write-Host "API URL: $apiUrl"
  Write-Host "Uploads bucket: $receiptsBucket"
  Write-Host "Expenses table: $expensesTable"
  Write-Host "Budgets table: $budgetsTable"
}
finally {
  if (Test-Path $workDir) {
    Remove-Item $workDir -Recurse -Force
  }
}