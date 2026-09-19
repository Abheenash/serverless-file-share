import json
import time


def post(mod, body):
    return mod.handler({"body": json.dumps(body)}, None)


def test_issues_presigned_put_and_records_metadata(issue, aws):
    r = post(issue, {"filename": "invoice.txt", "contentLength": 1234, "expiresInSeconds": 3600})
    assert r["statusCode"] == 201
    b = json.loads(r["body"])
    assert b["uploadUrl"].startswith("https://") and "X-Amz-Signature" in b["uploadUrl"]
    assert b["objectKey"] == f"files/{b['fileId']}/invoice.txt"
    assert b["uploadExpiresInSeconds"] == 900 and not b["passwordProtected"] and b["maxDownloads"] is None
    item = aws["ddb"].get_item(TableName="sfs-metadata-test", Key={"fileId": {"S": b["fileId"]}})["Item"]
    assert item["downloadCount"]["N"] == "0"
    assert abs(int(item["expiresAt"]["N"]) - (int(time.time()) + 3600)) <= 2


def test_lifetime_is_clamped_and_defaults(issue):
    b = json.loads(post(issue, {"contentLength": 1, "expiresInSeconds": 5})["body"])
    assert b["expiresAt"] - int(time.time()) in (59, 60, 61)
    b = json.loads(post(issue, {"contentLength": 1, "expiresInSeconds": 10**9})["body"])
    assert b["expiresAt"] - int(time.time()) <= 7 * 24 * 3600
    b = json.loads(post(issue, {"contentLength": 1})["body"])
    assert abs(b["expiresAt"] - int(time.time()) - 86400) <= 2
    assert post(issue, {"contentLength": 1, "expiresInSeconds": "soon"})["statusCode"] == 400


def test_size_cap_and_validation(issue):
    assert post(issue, {"contentLength": 0})["statusCode"] == 400
    assert post(issue, {"contentLength": "big"})["statusCode"] == 400
    assert post(issue, {"contentLength": 100 * 1024 * 1024 + 1})["statusCode"] == 413
    assert post(issue, {"contentLength": 100 * 1024 * 1024})["statusCode"] == 201
    assert issue.handler({"body": "{not json"}, None)["statusCode"] == 400
    assert issue.handler({"body": "[1]"}, None)["statusCode"] == 400


def test_filenames_are_sanitised(issue):
    sf = issue.safe_filename
    assert sf('../../etc/passwd') == "passwd"
    assert sf('C:\\Users\\me\\report.pdf') == "report.pdf"
    assert sf('bad"name\r\nX-Injected: yes.txt') == "badnameX-Injected: yes.txt"
    assert sf("") == "file" and sf(None) == "file" and sf("...") == "file"
    assert len(sf("x" * 500)) == 200
    assert sf("résumé.pdf") == "résumé.pdf"
    b = json.loads(post(issue, {"filename": "../evil\"x.txt", "contentLength": 1})["body"])
    assert b["objectKey"].endswith("/evilx.txt")


def test_optional_controls(issue, aws):
    r = post(issue, {"contentLength": 1, "password": "hunter2", "maxDownloads": 3, "notifyEmail": "a@b.co", "encrypted": True})
    b = json.loads(r["body"])
    assert b["passwordProtected"] and b["maxDownloads"] == 3 and b["notify"] and b["encrypted"]
    item = aws["ddb"].get_item(TableName="sfs-metadata-test", Key={"fileId": {"S": b["fileId"]}})["Item"]
    assert item["passwordHash"]["S"].startswith("pbkdf2$sha256$120000$") and "hunter2" not in item["passwordHash"]["S"]
    assert item["encrypted"]["BOOL"] is True
    assert post(issue, {"contentLength": 1, "maxDownloads": "many"})["statusCode"] == 400
    assert post(issue, {"contentLength": 1, "maxDownloads": 0})["statusCode"] == 201  # 0 == uncapped
    assert post(issue, {"contentLength": 1, "maxDownloads": -1})["statusCode"] == 400
    assert post(issue, {"contentLength": 1, "notifyEmail": "not-an-email"})["statusCode"] == 400
    b = json.loads(post(issue, {"contentLength": 1, "maxDownloads": 99999})["body"])
    assert b["maxDownloads"] == 1000


def test_each_password_hash_has_its_own_salt(issue):
    assert issue._hash_password("same") != issue._hash_password("same")
