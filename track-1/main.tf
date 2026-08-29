terraform {
  required_version = ">= 1.5"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

data "aws_caller_identity" "current" {}

variable "confluence_url" {
  type = string
}

variable "confluence_email" {
  type      = string
  sensitive = true
}

variable "confluence_api_token" {
  type      = string
  sensitive = true
}

variable "confluence_space_id" {
  type = string
}

locals {
  name = "s3-confluence-data-track-1"
}

resource "aws_s3_bucket" "input" {
  bucket        = "${local.name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_notification" "input" {
  bucket      = aws_s3_bucket.input.id
  eventbridge = true
}

resource "aws_iam_role" "publisher" {
  name = "${local.name}-publisher"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "publisher" {
  name              = "/aws/lambda/${local.name}-publisher"
  retention_in_days = 1
}

resource "aws_iam_role_policy" "publisher" {
  name = "read-input-and-write-logs"
  role = aws_iam_role.publisher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.input.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.publisher.arn}:*"
      },
    ]
  })
}

data "archive_file" "publisher" {
  type        = "zip"
  source_file = "${path.module}/publisher.py"
  output_path = "${path.module}/publisher.zip"
}

resource "aws_lambda_function" "publisher" {
  function_name    = "${local.name}-publisher"
  role             = aws_iam_role.publisher.arn
  handler          = "publisher.handler"
  runtime          = "python3.13"
  filename         = data.archive_file.publisher.output_path
  source_code_hash = data.archive_file.publisher.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      CONFLUENCE_API_TOKEN = var.confluence_api_token
      CONFLUENCE_EMAIL     = var.confluence_email
      CONFLUENCE_SPACE_ID  = var.confluence_space_id
      CONFLUENCE_URL       = trimsuffix(var.confluence_url, "/")
    }
  }

  depends_on = [aws_cloudwatch_log_group.publisher]
}

resource "aws_cloudwatch_event_rule" "json_created" {
  name = "${local.name}-json-created"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.input.id] }
      object = { key = [{ suffix = ".json" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "publisher" {
  rule = aws_cloudwatch_event_rule.json_created.name
  arn  = aws_lambda_function.publisher.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.publisher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.json_created.arn
}

output "bucket_name" {
  value = aws_s3_bucket.input.id
}

