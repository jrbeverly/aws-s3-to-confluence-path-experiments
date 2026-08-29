import base64
import html
import json
import os
import re
from urllib import error, request

import boto3


def confluence(method, path, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    authorization = base64.b64encode(
        (os.environ["CONFLUENCE_EMAIL"] + ":" + os.environ["CONFLUENCE_API_TOKEN"]).encode()
    ).decode()
    req = request.Request(os.environ["CONFLUENCE_URL"] + path, data=body, method=method)
    req.add_header("Accept", "application/json")
    req.add_header("Authorization", "Basic " + authorization)
    req.add_header("X-Atlassian-Token", "no-check")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=20) as response:
            return json.load(response) if response.length != 0 else None
    except error.HTTPError as exc:
        raise RuntimeError(f"Confluence {method} {path} returned {exc.code}") from None


def label(key, value):
    return re.sub(r"[^a-z0-9=]+", "-", f"{key}={value}".lower()).strip("-")[:255]


def handler(event, context):
    obj = boto3.client("s3").get_object(Bucket=event["bucket"], Key=event["key"])
    source = obj["Body"].read().decode()
    metadata = obj["Metadata"]

    page = confluence("POST", "/wiki/api/v2/pages", {
        "spaceId": os.environ["CONFLUENCE_SPACE_ID"],
        "status": "current",
        "title": metadata["title"],
        "parentId": metadata["parent"],
        "body": {
            "representation": "storage",
            "value": "<pre>" + html.escape(source) + "</pre>",
        },
    })
    confluence(
        "POST",
        "/wiki/rest/api/content/" + str(page["id"]) + "/label",
        [{"prefix": "global", "name": label(key, value)} for key, value in metadata.items()],
    )
    print(json.dumps({"bucket": event["bucket"], "key": event["key"], "pageId": str(page["id"])}))
    return {"pageId": str(page["id"])}

