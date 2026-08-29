#!/usr/bin/env bash
set -euo pipefail

e2e_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
experiment_dir=$(cd "$e2e_dir/../.." && pwd)

space_id=$(python3 "$e2e_dir/confluence.py" space-id)
export TF_VAR_confluence_url="$ATLASSIAN_URL"
export TF_VAR_confluence_email="$ATLASSIAN_EMAIL"
export TF_VAR_confluence_api_token="$ATLASSIAN_API_TOKEN"
export TF_VAR_confluence_space_id="$space_id"
export TF_VAR_confluence_space_key="$CONFLUENCE_SPACE"

for track in track-1 track-2a track-2b; do
  terraform -chdir="$experiment_dir/$track" init -input=false
  terraform -chdir="$experiment_dir/$track" apply -auto-approve -input=false
done

sleep 10

run_id=$(date +%s)
track_1_title="track-1-json-$run_id"
track_2a_title="track-2a-transcript-$run_id"
track_2b_title="track-2b-md2conf-$run_id"
state_file="$e2e_dir/.last-run"
printf 'RUN_ID=%q\nTRACK_1_TITLE=%q\nTRACK_2A_TITLE=%q\nTRACK_2B_TITLE=%q\n' \
  "$run_id" "$track_1_title" "$track_2a_title" "$track_2b_title" > "$state_file"

track_1_bucket=$(terraform -chdir="$experiment_dir/track-1" output -raw bucket_name)
aws s3api put-object \
  --bucket "$track_1_bucket" \
  --key "e2e/$run_id.json" \
  --body "$e2e_dir/fixture.json" \
  --content-type application/json \
  --metadata "parent=$CONFLUENCE_ROOT_PAGE_ID,title=$track_1_title,type=json,team=platform" \
  >/dev/null

read -r track_1_page_id track_1_page_url < <(
  python3 "$e2e_dir/confluence.py" wait "$track_1_title" "Track 1 JSON payload" "type=json"
)
printf 'TRACK_1_PAGE_ID=%q\n' "$track_1_page_id" >> "$state_file"
printf 'Track 1 page: %s\n' "$track_1_page_url"

audio_file=$(mktemp --suffix=.wav)
trap 'rm -f "$audio_file"' EXIT
espeak-ng -w "$audio_file" "The transcription publishing experiment reached Confluence."

track_2a_bucket=$(terraform -chdir="$experiment_dir/track-2a" output -raw bucket_name)
aws s3api put-object \
  --bucket "$track_2a_bucket" \
  --key "e2e/$run_id.wav" \
  --body "$audio_file" \
  --content-type audio/wav \
  --metadata "parent=$CONFLUENCE_ROOT_PAGE_ID,title=$track_2a_title,type=transcript,team=platform" \
  >/dev/null

read -r track_2a_page_id track_2a_page_url < <(
  python3 "$e2e_dir/confluence.py" wait "$track_2a_title" "WEBVTT" "type=transcript"
)
printf 'TRACK_2A_PAGE_ID=%q\n' "$track_2a_page_id" >> "$state_file"
printf 'Track 2A page: %s\n' "$track_2a_page_url"

track_2a_vtt=$(aws s3api list-objects-v2 --bucket "$track_2a_bucket" --prefix transcripts/ --output json | python3 -c 'import json,sys; objects=json.load(sys.stdin)["Contents"]; print(next(item["Key"] for item in sorted(objects, key=lambda item: item["LastModified"], reverse=True) if item["Key"].endswith(".vtt")))')
aws s3api head-object --bucket "$track_2a_bucket" --key "$track_2a_vtt" --output json | python3 -c 'import json,os,sys; metadata=json.load(sys.stdin)["Metadata"]; assert metadata == {"parent": os.environ["CONFLUENCE_ROOT_PAGE_ID"], "title": sys.argv[1], "type": "transcript", "team": "platform"}, metadata' "$track_2a_title"
track_2a_job=$(basename "$track_2a_vtt" .vtt)
printf 'TRACK_2A_JOB=%q\n' "$track_2a_job" >> "$state_file"

track_2b_bucket=$(terraform -chdir="$experiment_dir/track-2b" output -raw bucket_name)
aws s3api put-object \
  --bucket "$track_2b_bucket" \
  --key "e2e/$run_id.wav" \
  --body "$audio_file" \
  --content-type audio/wav \
  --metadata "parent=$CONFLUENCE_ROOT_PAGE_ID,title=$track_2b_title,type=transcript,team=platform" \
  >/dev/null

read -r track_2b_page_id track_2b_page_url < <(
  python3 "$e2e_dir/confluence.py" wait "$track_2b_title" "WEBVTT" "type=transcript"
)
printf 'TRACK_2B_PAGE_ID=%q\n' "$track_2b_page_id" >> "$state_file"
printf 'Track 2B page: %s\n' "$track_2b_page_url"

track_2b_vtt=$(aws s3api list-objects-v2 --bucket "$track_2b_bucket" --prefix transcripts/ --output json | python3 -c 'import json,sys; objects=json.load(sys.stdin)["Contents"]; print(next(item["Key"] for item in sorted(objects, key=lambda item: item["LastModified"], reverse=True) if item["Key"].endswith(".vtt")))')
track_2b_job=$(basename "$track_2b_vtt" .vtt)
printf 'TRACK_2B_JOB=%q\n' "$track_2b_job" >> "$state_file"
track_2b_markdown=$(aws s3api list-objects-v2 --bucket "$track_2b_bucket" --prefix markdown/ --output json | python3 -c 'import json,sys; objects=json.load(sys.stdin)["Contents"]; print(next(item["Key"] for item in objects if item["Key"].endswith(".md")))')
aws s3 cp "s3://$track_2b_bucket/$track_2b_markdown" - --no-progress | python3 -c 'import sys; body=sys.stdin.read(); assert "title: \"" + sys.argv[1] + "\"" in body; assert "type=transcript" in body; assert "WEBVTT" in body' "$track_2b_title"

printf 'All three publishing tracks passed. Run tests/e2e/destroy.sh after inspection.\n'
