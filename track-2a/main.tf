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
data "aws_partition" "current" {}

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
  name                   = "s3-confluence-data-track-2a"
  automation_definition  = "arn:${data.aws_partition.current.partition}:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.transcribe_and_publish.name}"
  automation_document    = "arn:${data.aws_partition.current.partition}:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:document/${aws_ssm_document.transcribe_and_publish.name}"
  automation_executions  = "arn:${data.aws_partition.current.partition}:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:automation-execution/*"
  transcription_job_name = "aws-s3-to-confluence-data-{{ automation:EXECUTION_ID }}"
  transcription_vtt_key  = "transcripts/{{ automation:EXECUTION_ID }}/${local.transcription_job_name}.vtt"
}

resource "aws_s3_bucket" "audio" {
  bucket        = "${local.name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_notification" "audio" {
  bucket      = aws_s3_bucket.audio.id
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
  name = "read-transcript-and-write-logs"
  role = aws_iam_role.publisher.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.audio.arn}/transcripts/*"
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

resource "aws_iam_role" "automation" {
  name = "${local.name}-automation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "automation" {
  name = "transcribe-copy-and-publish"
  role = aws_iam_role.automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
        ]
        Resource = "${aws_s3_bucket.audio.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "transcribe:GetTranscriptionJob",
          "transcribe:StartTranscriptionJob",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.publisher.arn
      },
    ]
  })
}

resource "aws_ssm_document" "transcribe_and_publish" {
  name            = "${local.name}-workflow"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Transcribe one S3 WAV object, copy source metadata to its VTT, and publish the VTT to Confluence."
    assumeRole    = aws_iam_role.automation.arn
    parameters = {
      SourceBucket = { type = "String" }
      SourceKey    = { type = "String" }
    }
    mainSteps = [
      {
        name           = "GetSourceMetadata"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        inputs = {
          Service = "s3"
          Api     = "HeadObject"
          Bucket  = "{{ SourceBucket }}"
          Key     = "{{ SourceKey }}"
        }
        outputs = [
          { Name = "Parent", Selector = "$.Metadata.parent", Type = "String" },
          { Name = "Title", Selector = "$.Metadata.title", Type = "String" },
          { Name = "Type", Selector = "$.Metadata.type", Type = "String" },
          { Name = "Team", Selector = "$.Metadata.team", Type = "String" },
        ]
      },
      {
        name           = "StartTranscription"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        inputs = {
          Service              = "transcribe"
          Api                  = "StartTranscriptionJob"
          TranscriptionJobName = local.transcription_job_name
          LanguageCode         = "en-US"
          MediaFormat          = "wav"
          Media = {
            MediaFileUri = "s3://{{ SourceBucket }}/{{ SourceKey }}"
          }
          OutputBucketName = "{{ SourceBucket }}"
          OutputKey        = "transcripts/{{ automation:EXECUTION_ID }}/"
          Subtitles = {
            Formats          = ["vtt"]
            OutputStartIndex = 1
          }
        }
      },
      {
        name           = "WaitForTranscription"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 900
        inputs = {
          Service              = "transcribe"
          Api                  = "GetTranscriptionJob"
          TranscriptionJobName = local.transcription_job_name
          PropertySelector     = "$.TranscriptionJob.TranscriptionJobStatus"
          DesiredValues        = ["COMPLETED"]
        }
      },
      {
        name           = "CopyPublishingMetadata"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        inputs = {
          Service           = "s3"
          Api               = "CopyObject"
          Bucket            = "{{ SourceBucket }}"
          Key               = local.transcription_vtt_key
          CopySource        = "{{ SourceBucket }}/${local.transcription_vtt_key}"
          MetadataDirective = "REPLACE"
          ContentType       = "text/vtt"
          Metadata = {
            parent = "{{ GetSourceMetadata.Parent }}"
            title  = "{{ GetSourceMetadata.Title }}"
            type   = "{{ GetSourceMetadata.Type }}"
            team   = "{{ GetSourceMetadata.Team }}"
          }
        }
      },
      {
        name           = "PublishToConfluence"
        action         = "aws:invokeLambdaFunction"
        timeoutSeconds = 60
        inputs = {
          FunctionName = aws_lambda_function.publisher.arn
          Payload = jsonencode({
            bucket = "{{ SourceBucket }}"
            key    = local.transcription_vtt_key
          })
        }
      },
    ]
  })
}

resource "aws_cloudwatch_event_rule" "audio_created" {
  name = "${local.name}-wav-created"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.audio.id] }
      object = { key = [{ suffix = ".wav" }] }
    }
  })
}

resource "aws_iam_role" "eventbridge" {
  name = "${local.name}-eventbridge"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge" {
  name = "start-automation"
  role = aws_iam_role.eventbridge.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ssm:StartAutomationExecution"
        Resource = [
          local.automation_document,
          local.automation_executions,
        ]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.automation.arn
      },
    ]
  })
}

resource "aws_cloudwatch_event_target" "automation" {
  rule     = aws_cloudwatch_event_rule.audio_created.name
  arn      = local.automation_definition
  role_arn = aws_iam_role.eventbridge.arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = <<-JSON
      {"SourceBucket":["<bucket>"],"SourceKey":["<key>"]}
    JSON
  }
}

output "bucket_name" {
  value = aws_s3_bucket.audio.id
}

output "automation_document_name" {
  value = aws_ssm_document.transcribe_and_publish.name
}
