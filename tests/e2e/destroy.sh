#!/usr/bin/env bash
set -euo pipefail

e2e_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
experiment_dir=$(cd "$e2e_dir/../.." && pwd)
state_file="$e2e_dir/.last-run"

space_id=$(python3 "$e2e_dir/confluence.py" space-id)
export TF_VAR_confluence_url="$ATLASSIAN_URL"
export TF_VAR_confluence_email="$ATLASSIAN_EMAIL"
export TF_VAR_confluence_api_token="$ATLASSIAN_API_TOKEN"
export TF_VAR_confluence_space_id="$space_id"
export TF_VAR_confluence_space_key="$CONFLUENCE_SPACE"

if [[ -f "$state_file" ]]; then
  source "$state_file"
  for variable in TRACK_1_TITLE TRACK_2A_TITLE TRACK_2B_TITLE; do
    title=${!variable-}
    if [[ -n "$title" ]]; then
      python3 "$e2e_dir/confluence.py" delete-title "$title"
    fi
  done
fi

aws transcribe list-transcription-jobs --job-name-contains aws-s3-to-confluence-data- --output json \
  | python3 -c 'import json,sys; print("\n".join(job["TranscriptionJobName"] for job in json.load(sys.stdin)["TranscriptionJobSummaries"] if job["TranscriptionJobName"].startswith("aws-s3-to-confluence-data-")))' \
  | while IFS= read -r job_name; do
      if [[ -n "$job_name" ]]; then
        aws transcribe delete-transcription-job --transcription-job-name "$job_name"
      fi
    done

for track in track-1 track-2a track-2b; do
  terraform -chdir="$experiment_dir/$track" init -input=false
  terraform -chdir="$experiment_dir/$track" destroy -auto-approve -input=false
done

rm -f "$state_file"
