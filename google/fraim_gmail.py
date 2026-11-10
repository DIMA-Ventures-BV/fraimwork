"""The signed-in Gmail account, for the services in the google container."""
import json
import os

DIR = os.environ.get("FRAIM_GOOGLE_DIR", "/data/google")


def credentials_file():
    with open(os.path.join(DIR, "email"), encoding="utf-8") as handle:
        return os.path.join(DIR, "credentials", f"{handle.read().strip()}.json")


def connect():
    from google.oauth2.credentials import Credentials
    from googleapiclient.discovery import build

    with open(credentials_file(), encoding="utf-8") as handle:
        data = json.load(handle)
    credentials = Credentials(
        token=data.get("token"),
        refresh_token=data.get("refresh_token"),
        token_uri=data.get("token_uri"),
        client_id=data.get("client_id"),
        client_secret=data.get("client_secret"),
        scopes=data.get("scopes"),
    )
    return build("gmail", "v1", credentials=credentials, cache_discovery=False)
