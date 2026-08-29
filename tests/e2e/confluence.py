import base64
import json
import os
import sys
import time
from urllib import error, parse, request


origin = os.environ["ATLASSIAN_URL"].rstrip("/")
authorization = base64.b64encode(
    (os.environ["ATLASSIAN_EMAIL"] + ":" + os.environ["ATLASSIAN_API_TOKEN"]).encode()
).decode()


def call(method, path, payload=None, expected=(200,)):
    body = None if payload is None else json.dumps(payload).encode()
    req = request.Request(origin + path, data=body, method=method)
    req.add_header("Accept", "application/json")
    req.add_header("Authorization", "Basic " + authorization)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with request.urlopen(req, timeout=30) as response:
            raw = response.read()
            if response.status not in expected:
                raise RuntimeError(f"Confluence {method} {path} returned {response.status}")
            return json.loads(raw) if raw else None
    except error.HTTPError as exc:
        if exc.code not in expected:
            raise RuntimeError(f"Confluence {method} {path} returned {exc.code}") from None
        return None


def space_id():
    key = parse.quote(os.environ["CONFLUENCE_SPACE"], safe="")
    spaces = call("GET", "/wiki/api/v2/spaces?keys=" + key + "&limit=2")["results"]
    if len(spaces) != 1:
        raise RuntimeError("expected one configured Confluence space")
    print(spaces[0]["id"])


def wait_for_page(title, text, expected_label):
    parent = parse.quote(os.environ["CONFLUENCE_ROOT_PAGE_ID"], safe="")
    for _ in range(90):
        children = call("GET", f"/wiki/api/v2/pages/{parent}/children?limit=100")["results"]
        matches = [page for page in children if page["title"] == title]
        if len(matches) == 1:
            page_id = str(matches[0]["id"])
            page = call("GET", f"/wiki/api/v2/pages/{page_id}?body-format=storage")
            labels = call("GET", f"/wiki/rest/api/content/{page_id}/label?limit=100")
            body = page["body"]["storage"]["value"]
            names = {item["name"] for item in labels["results"]}
            if text in body and expected_label in names:
                print(page_id, origin + "/wiki/pages/viewpage.action?pageId=" + page_id)
                return
        if len(matches) > 1:
            raise RuntimeError(f"multiple pages have title {title!r}")
        time.sleep(10)
    raise RuntimeError(f"timed out waiting for page {title!r}")


def delete_page(page_id):
    call("DELETE", "/wiki/api/v2/pages/" + parse.quote(page_id, safe=""), expected=(204, 404))
    call("DELETE", "/wiki/api/v2/pages/" + parse.quote(page_id, safe="") + "?purge=true", expected=(204, 404))


def delete_title(title):
    parent = parse.quote(os.environ["CONFLUENCE_ROOT_PAGE_ID"], safe="")
    children = call("GET", f"/wiki/api/v2/pages/{parent}/children?limit=100")["results"]
    for page in children:
        if page["title"] == title:
            delete_page(str(page["id"]))


if sys.argv[1] == "space-id":
    space_id()
elif sys.argv[1] == "wait":
    wait_for_page(sys.argv[2], sys.argv[3], sys.argv[4])
elif sys.argv[1] == "delete":
    delete_page(sys.argv[2])
elif sys.argv[1] == "delete-title":
    delete_title(sys.argv[2])
