terraform {
  required_version = ">= 1.5"

  required_providers {
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

variable "confluence_space_key" {
  type = string
}

locals {
  name                   = "s3-confluence-data-track-2b"
  automation_definition  = "arn:${data.aws_partition.current.partition}:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:automation-definition/${aws_ssm_document.transcribe_markdown_publish.name}"
  automation_document    = "arn:${data.aws_partition.current.partition}:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:document/${aws_ssm_document.transcribe_markdown_publish.name}"
  automation_executions  = "arn:${data.aws_partition.current.partition}:ssm:us-west-2:${data.aws_caller_identity.current.account_id}:automation-execution/*"
  transcription_job_name = "aws-s3-to-confluence-data-md2conf-{{ automation:EXECUTION_ID }}"
  transcription_vtt_key  = "transcripts/{{ automation:EXECUTION_ID }}/${local.transcription_job_name}.vtt"
  markdown_key           = "markdown/{{ automation:EXECUTION_ID }}.md"
  markdown_script        = <<-PYTHON
    import boto3
    import json

    def make(events, context):
        s3 = boto3.client("s3")
        vtt = s3.get_object(Bucket=events["bucket"], Key=events["vtt_key"])["Body"].read().decode()
        markdown = (
            "---\n"
            + "title: " + json.dumps(events["title"]) + "\n"
            + "tags: [" + json.dumps("type=" + events["type"])
            + ", " + json.dumps("team=" + events["team"]) + "]\n"
            + "---\n\n```text\n" + vtt + "\n```\n"
        )
        s3.put_object(
            Bucket=events["bucket"],
            Key=events["markdown_key"],
            Body=markdown.encode(),
            ContentType="text/markdown",
        )
        return {"MarkdownKey": events["markdown_key"]}
  PYTHON
}

resource "aws_s3_bucket" "audio" {
  bucket        = "${local.name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_notification" "audio" {
  bucket      = aws_s3_bucket.audio.id
  eventbridge = true
}

resource "aws_cloudwatch_log_group" "md2conf" {
  name              = "/aws/codebuild/${local.name}-md2conf"
  retention_in_days = 1
}

resource "aws_iam_role" "md2conf" {
  name = "${local.name}-md2conf"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "md2conf" {
  name = "read-markdown-and-write-logs"
  role = aws_iam_role.md2conf.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.audio.arn}/markdown/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.md2conf.arn}:*"
      },
    ]
  })
}

resource "aws_codebuild_project" "md2conf" {
  name         = "${local.name}-md2conf"
  service_role = aws_iam_role.md2conf.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"

    environment_variable {
      name  = "BUCKET"
      value = aws_s3_bucket.audio.id
    }

    environment_variable {
      name  = "CONFLUENCE_DOMAIN"
      value = trimprefix(trimsuffix(var.confluence_url, "/"), "https://")
    }

    environment_variable {
      name  = "CONFLUENCE_PATH"
      value = "/wiki/"
    }

    environment_variable {
      name  = "CONFLUENCE_USER_NAME"
      value = var.confluence_email
    }

    environment_variable {
      name  = "CONFLUENCE_API_KEY"
      value = var.confluence_api_token
    }

    environment_variable {
      name  = "CONFLUENCE_SPACE_KEY"
      value = var.confluence_space_key
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.md2conf.name
      stream_name = "build"
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = <<-YAML
      version: 0.2
      phases:
        install:
          commands:
            - pip3 install --quiet markdown-to-confluence==0.6.3
        build:
          commands:
            - aws s3 cp "s3://$BUCKET/$MARKDOWN_KEY" /tmp/transcript.md
            - python3 -m md2conf /tmp/transcript.md --root-page "$ROOT_PAGE_ID" --skip-update --no-generated-by
    YAML
  }
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
  name = "transcribe-create-markdown-and-build"
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
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild",
        ]
        Resource = aws_codebuild_project.md2conf.arn
      },
    ]
  })
}

resource "aws_ssm_document" "transcribe_markdown_publish" {
  name            = "${local.name}-workflow"
  document_type   = "Automation"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "Transcribe one S3 WAV object, create Markdown, and publish it with md2conf."
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
        name           = "CreateMarkdown"
        action         = "aws:executeScript"
        timeoutSeconds = 60
        inputs = {
          Runtime = "python3.11"
          Handler = "make"
          Script  = local.markdown_script
          InputPayload = {
            bucket       = "{{ SourceBucket }}"
            markdown_key = local.markdown_key
            team         = "{{ GetSourceMetadata.Team }}"
            title        = "{{ GetSourceMetadata.Title }}"
            type         = "{{ GetSourceMetadata.Type }}"
            vtt_key      = local.transcription_vtt_key
          }
        }
      },
      {
        name           = "StartMd2ConfBuild"
        action         = "aws:executeAwsApi"
        timeoutSeconds = 25
        inputs = {
          Service     = "codebuild"
          Api         = "StartBuild"
          projectName = aws_codebuild_project.md2conf.name
          environmentVariablesOverride = [
            { name = "MARKDOWN_KEY", value = local.markdown_key, type = "PLAINTEXT" },
            { name = "ROOT_PAGE_ID", value = "{{ GetSourceMetadata.Parent }}", type = "PLAINTEXT" },
          ]
        }
        outputs = [
          { Name = "BuildId", Selector = "$.build.id", Type = "String" },
        ]
      },
      {
        name           = "WaitForMd2Conf"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 900
        inputs = {
          Service          = "codebuild"
          Api              = "BatchGetBuilds"
          ids              = ["{{ StartMd2ConfBuild.BuildId }}"]
          PropertySelector = "$.builds[0].buildStatus"
          DesiredValues    = ["SUCCEEDED"]
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
  value = aws_ssm_document.transcribe_markdown_publish.name
}
