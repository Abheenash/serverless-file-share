import json
import time

from conftest import load


def seed(aws, issue, **extra):
    r = issue.handler({"body": json.dumps({"filename": "doc.txt", "contentLength": 3, **extra})}, None)
    fid = json.loads(r["body"])["fileId"]
    key = json.loads(r["body"])["objectKey"]
    aws["s3"].put_object(Bucket="sfs-files-test", Key=key, Body=b"hey")
    return fid


def call(mod, fid, method="GET", body=None):
    return mod.handler({"requestContext": {"http": {"method": method}}, "pathParameters": {"fileId": fid},
                        "body": json.dumps(body) if body is not None else None}, None)


def test_info_then_fetch(download, aws):
    issue = load("issue_url")
    fid = seed(aws, issue)
    info = json.loads(call(download, fid)["body"])
    assert info["filename"] == "doc.txt" and not info["passwordProtected"] and info["downloadsLeft"] is None
    r = call(download, fid, "POST", {})
    assert r["statusCode"] == 200
    url = json.loads(r["body"])["downloadUrl"]
    assert "response-content-disposition=" in url and "X-Amz-Signature" in url
    item = aws["ddb"].get_item(TableName="sfs-metadata-test", Key={"fileId": {"S": fid}})["Item"]
    assert item["downloadCount"]["N"] == "1"


def test_missing_and_expired_links_are_gone(download, aws):
    assert call(download, "nope")["statusCode"] == 410
    assert download.handler({"requestContext": {}, "pathParameters": {}}, None)["statusCode"] == 400
    aws["ddb"].put_item(TableName="sfs-metadata-test", Item={"fileId": {"S": "old"}, "expiresAt": {"N": str(int(time.time()) - 5)},
                                                              "objectKey": {"S": "files/old/x"}})
    assert call(download, "old")["statusCode"] == 410
    assert call(download, "old", "POST", {})["statusCode"] == 410


def test_password_gate(download, aws):
    issue = load("issue_url")
    fid = seed(aws, issue, password="hunter2")
    assert json.loads(call(download, fid)["body"])["passwordProtected"]
    assert call(download, fid, "POST", {})["statusCode"] == 401
    assert call(download, fid, "POST", {"password": "wrong"})["statusCode"] == 401
    assert call(download, fid, "POST", {"password": "hunter2"})["statusCode"] == 200
    assert download._verify_password("x", "garbage") is False


def test_download_cap_is_enforced_atomically(download, aws):
    issue = load("issue_url")
    fid = seed(aws, issue, maxDownloads=2)
    assert json.loads(call(download, fid)["body"])["downloadsLeft"] == 2
    assert call(download, fid, "POST", {})["statusCode"] == 200
    assert call(download, fid, "POST", {})["statusCode"] == 200
    assert call(download, fid, "POST", {})["statusCode"] == 410
    assert json.loads(call(download, fid)["body"])["gone"] is True


def test_notification_is_best_effort(download, aws):
    issue = load("issue_url")
    fid = seed(aws, issue, notifyEmail="owner@example.com")
    assert call(download, fid, "POST", {})["statusCode"] == 200
    assert aws["ses"].get_send_quota()["SentLast24Hours"] == 1.0
    # SES failing must never block the download
    download.SES_SENDER = "unverified@example.com"
    assert call(download, fid, "POST", {})["statusCode"] == 200


def test_content_disposition_is_injection_safe(download):
    cd = download.content_disposition('evil"; filename="x\r\nX-Injected: 1.txt')
    assert "\r" not in cd and "\n" not in cd
    assert cd.startswith('attachment; filename="evil_; filename=_x__X-Injected: 1.txt"; filename*=UTF-8\'\'')
    assert "%0D%0A" in cd
    assert download.content_disposition("résumé.pdf").endswith("filename*=UTF-8''r%C3%A9sum%C3%A9.pdf")
    assert 'filename="r_sum_.pdf"' in download.content_disposition("résumé.pdf")


def test_item_without_object_key_is_gone_not_500(download, aws):
    aws["ddb"].put_item(TableName="sfs-metadata-test", Item={"fileId": {"S": "half"}, "expiresAt": {"N": str(int(time.time()) + 500)}})
    assert call(download, "half", "POST", {})["statusCode"] == 410
