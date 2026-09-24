"""End-to-end tests against LocalStack — real S3, DynamoDB and SES.

The other three test files run these handlers against moto. That covers the
control flow well, and it cannot cover the one thing this product actually is: a
presigned URL that a browser uses directly. moto can *generate* a presigned URL,
but nothing in that suite ever sends an HTTP request to one, so the signature is
never validated by anything.

These tests do. `issue-url` mints a presigned PUT, the test uploads bytes to that
URL over plain HTTP with no AWS credentials at all, and then `download` mints a
presigned GET and the test fetches the bytes back the same way. If the signature,
the SigV4 version, the ContentLength binding or the key were wrong, moto would
still pass and this would not.

No application code changed to make this work: botocore resolves
`AWS_ENDPOINT_URL` natively, so pointing the handlers at LocalStack is
configuration. Everything exercised here is the code that runs in Lambda.

Skipped when LocalStack is not running; CI sets `REQUIRE_LOCALSTACK=1` so a
container that fails to start is an error rather than quiet skips.
"""

import contextlib
import importlib.util
import json
import os
import socket
import time
import urllib.error
import urllib.request

import boto3
import pytest

ENDPOINT = os.environ.get("AWS_ENDPOINT_URL", "http://127.0.0.1:4566")
BUCKET = "sfs-files-integration"
TABLE = "sfs-metadata-integration"
SENDER = "noreply@example.com"
ROOT = os.path.join(os.path.dirname(__file__), "..", "src")


def _localstack_is_up() -> bool:
    host, _, port = ENDPOINT.removeprefix("http://").removeprefix("https://").partition(":")
    try:
        with socket.create_connection((host, int(port or 80)), timeout=2):
            return True
    except OSError:
        return False


_UP = _localstack_is_up()

if os.environ.get("REQUIRE_LOCALSTACK") == "1" and not _UP:
    raise RuntimeError(
        f"REQUIRE_LOCALSTACK=1 but nothing is listening on {ENDPOINT}. These tests "
        "were meant to run, not to be skipped."
    )

pytestmark = pytest.mark.skipif(
    not _UP,
    reason=f"no LocalStack on {ENDPOINT} — run: docker run -d -p 4566:4566 "
           "-e SERVICES=s3,dynamodb,ses localstack/localstack:4.9",
)


def _load(name):
    """Import src/<name>/lambda_function.py — they all share a filename."""
    path = os.path.join(ROOT, name, "lambda_function.py")
    spec = importlib.util.spec_from_file_location(f"{name}_ls", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def aws():
    # MonkeyPatch.context(), not os.environ.update(). These variables point boto3
    # at LocalStack, and the other three test files in this directory run against
    # moto — moto does not intercept a client that was given an explicit endpoint,
    # so leaking AWS_ENDPOINT_URL out of this module makes every moto test in the
    # run fail with ResourceNotFound. Setting them globally did exactly that; the
    # context manager restores the environment when this module finishes.
    with pytest.MonkeyPatch.context() as mp:
        for k, v in {
            "AWS_ENDPOINT_URL": ENDPOINT,
            "AWS_DEFAULT_REGION": "us-east-1",
            "AWS_ACCESS_KEY_ID": "test",
            "AWS_SECRET_ACCESS_KEY": "test",
            "BUCKET": BUCKET,
            "TABLE": TABLE,
            "SES_SENDER": SENDER,
        }.items():
            mp.setenv(k, v)
        yield _provision()


def _provision():
    s3 = boto3.client("s3", endpoint_url=ENDPOINT, region_name="us-east-1")
    ddb = boto3.client("dynamodb", endpoint_url=ENDPOINT, region_name="us-east-1")
    ses = boto3.client("ses", endpoint_url=ENDPOINT, region_name="us-east-1")
    streams = boto3.client("dynamodbstreams", endpoint_url=ENDPOINT, region_name="us-east-1")
    with contextlib.suppress(s3.exceptions.ClientError):
        s3.create_bucket(Bucket=BUCKET)
    try:
        ddb.create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "fileId", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "fileId", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
            # The reaper is triggered by DynamoDB Streams and reads OldImage. A
            # hand-written event would only prove the reaper parses the shape the
            # test author believed in, so the stream is turned on and the test
            # feeds it the record DynamoDB actually emits.
            StreamSpecification={"StreamEnabled": True, "StreamViewType": "NEW_AND_OLD_IMAGES"},
        )
        ddb.get_waiter("table_exists").wait(TableName=TABLE)
    except ddb.exceptions.ResourceInUseException:
        pass  # the table surviving a previous run is the expected case
    ses.verify_email_identity(EmailAddress=SENDER)
    return {"s3": s3, "ddb": ddb, "ses": ses, "streams": streams}


@pytest.fixture(scope="module")
def issue(aws):
    return _load("issue_url")


@pytest.fixture(scope="module")
def download(aws):
    return _load("download")


def _issue(issue, **body):
    body.setdefault("filename", "notes.txt")
    body.setdefault("contentLength", 11)
    r = issue.handler({"body": json.dumps(body)}, None)
    assert r["statusCode"] == 201, r["body"]
    return json.loads(r["body"])


def _require_http(url: str) -> str:
    """ruff's S310 flags urlopen on a non-literal URL, because urlopen will happily
    open `file://` and read the local disk. The URL here is one our own Lambda just
    signed, but "it comes from our code" is the reasoning behind most SSRF bugs, so
    the scheme is checked rather than assumed — which is what the rule is asking
    for, and what makes the noqa below honest rather than a silencer."""
    if not url.startswith(("http://", "https://")):
        raise ValueError(f"refusing to open a non-HTTP URL: {url[:40]!r}")
    return url


def _put(url: str, data: bytes) -> int:
    """Upload to a presigned URL with NO credentials — the way a browser does."""
    req = urllib.request.Request(_require_http(url), data=data, method="PUT")  # noqa: S310 -- scheme checked
    with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310 -- scheme checked above
        return resp.status


def _get(url: str) -> bytes:
    with urllib.request.urlopen(_require_http(url), timeout=15) as resp:  # noqa: S310 -- scheme checked above
        return resp.read()


def test_presigned_put_actually_works_unauthenticated(issue, aws):
    """The product's core claim: the URL alone is enough to upload, and nothing
    but that URL is needed. Signed by the function's role, sent with no
    credentials."""
    payload = b"hello world"
    out = _issue(issue, filename="notes.txt", contentLength=len(payload))
    assert _put(out["uploadUrl"], payload) in (200, 204)

    stored = aws["s3"].get_object(Bucket=BUCKET, Key=out["objectKey"])["Body"].read()
    assert stored == payload


def test_the_signature_is_really_checked(issue, aws):
    """A tampered signature must be rejected. Against moto this test would be
    meaningless — nothing validates the signature there."""
    out = _issue(issue)
    bad = out["uploadUrl"].replace("Signature=", "Signature=x") if "Signature=" in out["uploadUrl"] \
        else out["uploadUrl"][:-4] + "0000"
    with pytest.raises(urllib.error.HTTPError) as raised:
        _put(bad, b"hello world")
    assert raised.value.code in (400, 403)


def test_content_length_binding_is_enforced_by_s3(issue):
    """issue-url signs the PUT with an exact ContentLength so the open endpoint
    cannot be used as unbounded free storage. That cap is enforced by S3, not by
    our code, so it can only be proven against a real S3 implementation."""
    out = _issue(issue, filename="small.txt", contentLength=11)
    with pytest.raises(urllib.error.HTTPError) as raised:
        _put(out["uploadUrl"], b"x" * 5000)  # far larger than the signed length
    assert raised.value.code in (400, 403)


def test_full_round_trip_upload_then_download(issue, download):
    payload = b"round trip!"
    out = _issue(issue, filename="round.txt", contentLength=len(payload))
    _put(out["uploadUrl"], payload)

    info = download.handler(
        {"pathParameters": {"fileId": out["fileId"]},
         "requestContext": {"http": {"method": "GET"}}}, None)
    assert info["statusCode"] == 200, info["body"]
    assert json.loads(info["body"])["filename"] == "round.txt"

    fetched = download.handler(
        {"pathParameters": {"fileId": out["fileId"]},
         "requestContext": {"http": {"method": "POST"}}, "body": "{}"}, None)
    assert fetched["statusCode"] == 200, fetched["body"]
    assert _get(json.loads(fetched["body"])["downloadUrl"]) == payload


def test_password_gate_against_real_dynamodb(issue, download):
    payload = b"secret data"
    out = _issue(issue, filename="secret.txt", contentLength=len(payload), password="hunter2")
    _put(out["uploadUrl"], payload)
    assert out["passwordProtected"] is True

    ev = {"pathParameters": {"fileId": out["fileId"]},
          "requestContext": {"http": {"method": "POST"}}}
    assert download.handler({**ev, "body": json.dumps({"password": "wrong"})}, None)["statusCode"] == 401
    assert download.handler({**ev, "body": "{}"}, None)["statusCode"] == 401
    ok = download.handler({**ev, "body": json.dumps({"password": "hunter2"})}, None)
    assert ok["statusCode"] == 200, ok["body"]
    assert _get(json.loads(ok["body"])["downloadUrl"]) == payload


def test_download_cap_is_enforced_by_a_real_conditional_update(issue, download):
    """The cap is a DynamoDB ConditionExpression (`downloadCount < maxDownloads`),
    so what enforces it is the database, not the handler. Worth running against
    the real engine: the 4th attempt has to be refused by the condition, and the
    handler has to turn that refusal into a 410 rather than a 500."""
    payload = b"limited!!!!"
    out = _issue(issue, filename="limited.txt", contentLength=len(payload), maxDownloads=3)
    _put(out["uploadUrl"], payload)
    assert out["maxDownloads"] == 3

    ev = {"pathParameters": {"fileId": out["fileId"]},
          "requestContext": {"http": {"method": "POST"}}, "body": "{}"}
    codes = [download.handler(ev, None)["statusCode"] for _ in range(4)]
    assert codes == [200, 200, 200, 410], codes

    info = download.handler(
        {"pathParameters": {"fileId": out["fileId"]},
         "requestContext": {"http": {"method": "GET"}}}, None)
    assert info["statusCode"] == 410


def test_an_expired_link_is_410_even_though_the_object_still_exists(issue, download, aws):
    """DynamoDB TTL deletes expired items within 48 hours, not on the second, so
    the handler must treat `expiresAt <= now` as gone regardless of whether the
    row is still there. That gap is invisible in a mock that cleans up eagerly,
    and it is the difference between a link that dies on time and one that keeps
    working for two days."""
    payload = b"expire me!!"
    out = _issue(issue, filename="expire.txt", contentLength=len(payload))
    _put(out["uploadUrl"], payload)

    aws["ddb"].update_item(
        TableName=TABLE, Key={"fileId": {"S": out["fileId"]}},
        UpdateExpression="SET expiresAt = :past",
        ExpressionAttributeValues={":past": {"N": str(int(time.time()) - 60)}},
    )

    assert download.handler(
        {"pathParameters": {"fileId": out["fileId"]},
         "requestContext": {"http": {"method": "GET"}}}, None)["statusCode"] == 410
    # the row and the object are both still present — only the handler says no
    assert aws["ddb"].get_item(TableName=TABLE, Key={"fileId": {"S": out["fileId"]}}).get("Item")
    assert aws["s3"].head_object(Bucket=BUCKET, Key=out["objectKey"])["ContentLength"] == len(payload)


def test_reaper_deletes_the_object_for_a_real_stream_record(issue, aws):
    """The reaper's whole contract is that a REMOVE record from DynamoDB Streams
    carries `OldImage.objectKey`, and TTL expiry is what produces that record. A
    hand-written event only proves the reaper parses what the test author
    imagined, so this reads the record DynamoDB itself emitted.

    TTL deletion is not simulated here — DynamoDB's own TTL sweeper runs within
    48 hours, not on demand — so the item is deleted explicitly. The resulting
    REMOVE record has the same shape either way, which is the part the reaper
    depends on.
    """
    payload = b"reap me!!!!"
    out = _issue(issue, filename="reap.txt", contentLength=len(payload))
    _put(out["uploadUrl"], payload)
    aws["s3"].head_object(Bucket=BUCKET, Key=out["objectKey"])  # it is really there

    stream_arn = aws["ddb"].describe_table(TableName=TABLE)["Table"]["LatestStreamArn"]
    shard = aws["streams"].describe_stream(StreamArn=stream_arn)["StreamDescription"]["Shards"][-1]
    iterator = aws["streams"].get_shard_iterator(
        StreamArn=stream_arn, ShardId=shard["ShardId"], ShardIteratorType="LATEST"
    )["ShardIterator"]

    aws["ddb"].delete_item(TableName=TABLE, Key={"fileId": {"S": out["fileId"]}})

    records, deadline = [], time.time() + 30
    while time.time() < deadline:
        page = aws["streams"].get_records(ShardIterator=iterator, Limit=100)
        iterator = page.get("NextShardIterator")
        records.extend(r for r in page.get("Records", []) if r.get("eventName") == "REMOVE")
        if any(r["dynamodb"].get("OldImage", {}).get("fileId", {}).get("S") == out["fileId"]
               for r in records):
            break
        time.sleep(1)

    mine = [r for r in records
            if r["dynamodb"].get("OldImage", {}).get("fileId", {}).get("S") == out["fileId"]]
    assert mine, "DynamoDB Streams never produced a REMOVE record for this item"
    # the assumption the reaper is built on, now checked rather than assumed
    assert mine[0]["dynamodb"]["OldImage"]["objectKey"]["S"] == out["objectKey"]

    result = _load("reaper").handler({"Records": mine}, None)
    assert result["deleted"] == 1
    assert result["batchItemFailures"] == []

    with pytest.raises(aws["s3"].exceptions.ClientError) as raised:
        aws["s3"].head_object(Bucket=BUCKET, Key=out["objectKey"])
    assert raised.value.response["Error"]["Code"] in ("404", "NoSuchKey")
