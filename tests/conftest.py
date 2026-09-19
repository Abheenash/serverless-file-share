import importlib
import os
import sys

import boto3
import pytest
from moto import mock_aws

os.environ.update({
    "AWS_DEFAULT_REGION": "us-east-1", "AWS_ACCESS_KEY_ID": "testing", "AWS_SECRET_ACCESS_KEY": "testing",
    "BUCKET": "sfs-files-test", "TABLE": "sfs-metadata-test", "SES_SENDER": "noreply@example.com",
})
ROOT = os.path.join(os.path.dirname(__file__), "..", "src")


def load(name):
    """Import src/<name>/lambda_function.py under a unique module name (they all share a filename)."""
    path = os.path.join(ROOT, name, "lambda_function.py")
    spec = importlib.util.spec_from_file_location(f"{name}_fn", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def aws():
    with mock_aws():
        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="sfs-files-test")
        ddb = boto3.client("dynamodb", region_name="us-east-1")
        ddb.create_table(TableName="sfs-metadata-test", KeySchema=[{"AttributeName": "fileId", "KeyType": "HASH"}],
                         AttributeDefinitions=[{"AttributeName": "fileId", "AttributeType": "S"}], BillingMode="PAY_PER_REQUEST")
        ses = boto3.client("ses", region_name="us-east-1")
        ses.verify_email_identity(EmailAddress="noreply@example.com")
        yield {"s3": s3, "ddb": ddb, "ses": ses}


@pytest.fixture
def issue(aws):
    return load("issue_url")


@pytest.fixture
def download(aws):
    return load("download")


@pytest.fixture
def reaper(aws):
    return load("reaper")
