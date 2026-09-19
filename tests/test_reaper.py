def rec(name, key, seq="1"):
    r = {"eventName": name, "dynamodb": {"SequenceNumber": seq}}
    if key is not None:
        r["dynamodb"]["OldImage"] = {"objectKey": {"S": key}}
    return r


def test_reaps_removed_items_only(reaper, aws):
    for k in ("files/a/x", "files/b/y", "files/c/z"):
        aws["s3"].put_object(Bucket="sfs-files-test", Key=k, Body=b"1")
    out = reaper.handler({"Records": [rec("REMOVE", "files/a/x"), rec("INSERT", "files/b/y", "2"),
                                      rec("REMOVE", None, "3"), rec("REMOVE", "files/c/z", "4")]}, None)
    assert out == {"deleted": 2, "batchItemFailures": []}
    keys = {o["Key"] for o in aws["s3"].list_objects_v2(Bucket="sfs-files-test").get("Contents", [])}
    assert keys == {"files/b/y"}


def test_failed_delete_is_reported_for_retry_not_whole_batch(reaper, aws, monkeypatch):
    aws["s3"].put_object(Bucket="sfs-files-test", Key="files/ok/1", Body=b"1")
    real = reaper.s3.delete_object

    def flaky(Bucket, Key):
        if Key == "files/bad/2":
            raise reaper.ClientError({"Error": {"Code": "InternalError", "Message": "boom"}}, "DeleteObject")
        return real(Bucket=Bucket, Key=Key)
    monkeypatch.setattr(reaper.s3, "delete_object", flaky)
    out = reaper.handler({"Records": [rec("REMOVE", "files/ok/1", "10"), rec("REMOVE", "files/bad/2", "11")]}, None)
    assert out["deleted"] == 1
    assert out["batchItemFailures"] == [{"itemIdentifier": "11"}]


def test_empty_batch(reaper):
    assert reaper.handler({}, None) == {"deleted": 0, "batchItemFailures": []}
