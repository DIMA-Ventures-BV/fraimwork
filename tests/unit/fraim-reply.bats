#!/usr/bin/env bats
# The mail rules of google/fraim-reply: who an answer goes to, and how it is built.

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../google/fraim-reply"
  export SCRIPT PYTHONDONTWRITEBYTECODE=1
}

py() {
  python3 -c "
import importlib.machinery, importlib.util, os, email
loader = importlib.machinery.SourceFileLoader('fraim_reply', os.environ['SCRIPT'])
spec = importlib.util.spec_from_loader('fraim_reply', loader)
r = importlib.util.module_from_spec(spec); loader.exec_module(r)
def m(labels, **h):
    return {'labelIds': labels, 'payload': {'headers': [{'name': k.replace('_', '-'), 'value': v} for k, v in h.items()]}}
$1"
}

@test "answers the newest message from someone else, never the owner's own" {
  run py "print(r.recipient(r.last_incoming([m(['INBOX'], From='Anna <anna@example.com>'), m(['SENT'], From='me@example.com')])))"
  [ "$status" -eq 0 ]
  [[ "$output" == *"anna@example.com"* ]]
}

@test "Reply-To wins over From" {
  run py "print(r.recipient(m([], From='Anna <anna@example.com>', Reply_To='Desk <desk@example.com>')))"
  [[ "$output" == *"desk@example.com"* ]]
}

@test "refuses a chain only the owner wrote in" {
  run py "
try:
    r.last_incoming([m(['SENT'], From='me@example.com')])
except r.Refused as e:
    print(e.status)"
  [ "$output" = "422" ]
}

@test "the reply keeps the chain together and adds Re: once" {
  run py "
raw = r.build_reply('me@example.com', 'anna@example.com', m([], Subject='Re: Login', Message_ID='<b@x>', References='<a@x>'), 'Hello')
import base64
msg = email.message_from_bytes(base64.urlsafe_b64decode(raw))
print(msg['Subject'], '|', msg['In-Reply-To'], '|', msg['References'], '|', msg['To'])"
  [ "$output" = "Re: Login | <b@x> | <a@x> <b@x> | anna@example.com" ]
}

@test "a subject without Re: gets one" {
  run py "print(r.subject_of(m([], Subject='Login')))"
  [ "$output" = "Re: Login" ]
}
