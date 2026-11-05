#!/bin/sh
# Runs on the host: sh check.sh, or podman exec -i circuit-homeassistant sh < check.sh.
# The test hosts may have no curl or Python, so the checks run with Python in
# the Home Assistant container, which shares the host's network.
#
# The first run finishes onboarding through Home Assistant's API, creating
# the owner "ci". Every run then signs in as that owner, checks a wrong
# password is refused, reads /api/config with the token, and checks nothing
# answers on the host's own address, since the web server listens on
# 127.0.0.1 only.
set -eu
want=${WANT_VERSION:-}
podman exec -i -e WANT_VERSION="$want" homeassistant python3 - <<'PY'
import json, os, socket, sys, time, urllib.error, urllib.parse, urllib.request

BASE = "http://127.0.0.1:8123"
CLIENT = BASE + "/"
PASSWORD = "Correct-horse-battery-9"


def call(path, data=None, form=False, token=None):
    headers = {}
    body = None
    if data is not None:
        if form:
            body = urllib.parse.urlencode(data).encode()
            headers["content-type"] = "application/x-www-form-urlencoded"
        else:
            body = json.dumps(data).encode()
            headers["content-type"] = "application/json"
    if token:
        headers["authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


# The web server opens its port before the onboarding API is ready.
for _ in range(600):
    try:
        status, steps = call("/api/onboarding")
        if status == 200 and isinstance(steps, list):
            break
    except OSError:
        pass
    time.sleep(1)
else:
    fail("the onboarding API didn't answer in 10 minutes")

user_step = next(s for s in steps if s["step"] == "user")
if not user_step["done"]:
    status, out = call("/api/onboarding/users", {"client_id": CLIENT, "name": "CI", "username": "ci", "password": PASSWORD, "language": "en"})
    if status != 200 or "auth_code" not in out:
        fail("onboarding refused the owner: %s %s" % (status, out))
    print("onboarding: created the owner")
    # A second owner can't be made once the step is done.
    status, _ = call("/api/onboarding/users", {"client_id": CLIENT, "name": "X", "username": "x", "password": PASSWORD, "language": "en"})
    if status != 403:
        fail("onboarding took a second owner: %s" % status)


def login(password):
    status, flow = call("/auth/login_flow", {"client_id": CLIENT, "handler": ["homeassistant", None], "redirect_uri": CLIENT})
    if status != 200:
        fail("login flow: %s %s" % (status, flow))
    return call("/auth/login_flow/" + flow["flow_id"], {"client_id": CLIENT, "username": "ci", "password": password})


status, out = login("Wrong-password-1")
if status != 200 or out.get("type") != "form" or out.get("errors", {}).get("base") != "invalid_auth":
    fail("a wrong password wasn't refused: %s %s" % (status, out))

status, out = login(PASSWORD)
if status != 200 or out.get("type") != "create_entry":
    fail("the owner couldn't sign in: %s %s" % (status, out))
status, tokens = call("/auth/token", {"grant_type": "authorization_code", "code": out["result"], "client_id": CLIENT}, form=True)
if status != 200:
    fail("token: %s %s" % (status, tokens))
token = tokens["access_token"]

status, config = call("/api/config", token=token)
if status != 200:
    fail("/api/config: %s %s" % (status, config))
if os.environ["WANT_VERSION"] and config["version"] != os.environ["WANT_VERSION"]:
    fail("running %s, wanted %s" % (config["version"], os.environ["WANT_VERSION"]))
status, _ = call("/api/config")
if status != 401:
    fail("/api/config answered without a token: %s" % status)
print("signed in as the owner; Home Assistant " + config["version"])

# The host's own address, from the route out. Nothing is sent.
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(("192.0.2.1", 9))
addr = s.getsockname()[0]
s.close()
try:
    socket.create_connection((addr, 8123), timeout=3).close()
    fail("port 8123 answers on %s, not only on 127.0.0.1" % addr)
except OSError:
    print("nothing answers on %s:8123" % addr)
print("All checks passed.")
PY
