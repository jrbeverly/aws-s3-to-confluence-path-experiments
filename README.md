# S3 to Confluence Path Experiments

> [!WARNING]
> **AI-authored:** This change was autonomously planned and implemented by an AI software factory from a human-authored specification, with possible subsequent human review or modification.

Compares three ways to publish S3 objects to Confluence with their S3 user metadata turned into labels. Track 1 sends JSON from EventBridge to a Lambda. Tracks 2A and 2B send a WAV from EventBridge to SSM Automation and Amazon Transcribe; 2A then publishes the VTT with a standard-library Lambda, while 2B builds Markdown and runs `md2conf` in CodeBuild. Each track is its own Terraform root.

```sh
export ATLASSIAN_URL=... ATLASSIAN_EMAIL=... ATLASSIAN_API_TOKEN=... CONFLUENCE_SPACE=... CONFLUENCE_ROOT_PAGE_ID=...
tests/e2e/run.sh       # needs espeak-ng for the test audio
tests/e2e/destroy.sh   # deletes the pages and transcription jobs, then destroys every root
```

## Notes

- Confluence accepts `key=value` labels. All three tracks now publish metadata as `type=json`, `team=platform` and so on, and `md2conf` passes `type=transcript` front-matter tags through unchanged. The earlier claim that labels needed `key-value` was wrong. The real limits are lowercase names and no spaces, so values are still normalised to `[a-z0-9=-]`.
- S3 `HeadObject` gives SSM Automation the user metadata without reading the body.
- `CopyObject` with `MetadataDirective=REPLACE` puts the source metadata onto the generated VTT before the publisher reads it.
- An EventBridge target for SSM Automation uses an `automation-definition` ARN, but its role needs `ssm:StartAutomationExecution` on both the `document` ARN and `automation-execution/*`.
- `md2conf` creates the page before it applies the final body and labels, so a verifier must wait for the page to settle.
- `md2conf` needs a full runtime with pip installs, so Track 2B uses CodeBuild (install 21 s, publish 19 s). Track 2A needs only a small standard-library Lambda.
- Live run: all three tracks passed in 255 s, including apply. The 2A Automation ran upload to page in 20 s for a 3.5 s espeak clip. 2B took 2 min 11 s, most of it CodeBuild provisioning and polling.
- Deleting a page through the v2 API only moves it to the trash (a later `GET` still returns 200 with `status: trashed`). A second `DELETE ...?purge=true` removes it for good.
