#!/usr/bin/env bats
# google/fraim-mail-watch: which mail counts as new, and that a crash never loses one.

setup() {
  export SCRIPT="$BATS_TEST_DIRNAME/../../google/fraim-mail-watch" PYTHONDONTWRITEBYTECODE=1
  export FRAIM_GOOGLE_DIR="$BATS_TEST_TMPDIR" EVENTS="$BATS_TEST_TMPDIR/events.jsonl"
}

py() {
  python3 -c "
import importlib.machinery, importlib.util, json, os
loader = importlib.machinery.SourceFileLoader('watch', os.environ['SCRIPT'])
spec = importlib.util.spec_from_loader('watch', loader)
w = importlib.util.module_from_spec(spec); loader.exec_module(w)
EVENTS = os.environ['EVENTS']
class Run:
    def __init__(self, fn): self.fn = fn
    def execute(self): return self.fn()
class Gone(Exception):
    class resp: status = 404
class Gmail:
    def __init__(self, pages=None, gone=False):
        self.pages, self.gone, self.watched = list(pages or []), gone, []
    def users(self): return self
    def history(self): return self
    def list(self, **kw):
        def go():
            if self.gone: raise Gone()
            return self.pages.pop(0)
        return Run(go)
    def getProfile(self, userId): return Run(lambda: {'historyId': '900'})
    def watch(self, userId, body):
        self.watched.append(body)
        return Run(lambda: {'expiration': '1700000000000'})
def added(id, thread, *labels):
    return {'messagesAdded': [{'message': {'id': id, 'threadId': thread, 'labelIds': list(labels)}}]}
$1"
}

@test "only new mail in the inbox counts, once each" {
  run py "print(json.dumps(w.new_mail([added('a','t1','INBOX'), added('a','t1','INBOX'), added('b','t2','INBOX','CATEGORY_PROMOTIONS'), added('c','t3','SENT','INBOX'), added('d','t4','DRAFT')])))"
  [ "$status" -eq 0 ]
  [ "$output" = '[{"id": "a", "thread": "t1"}]' ]
}

@test "the first look only remembers where the mailbox is" {
  run py "
s = {}
print(w.look(Gmail(), s, EVENTS), s['history_id'], os.path.exists(EVENTS))"
  [ "$output" = "0 900 False" ]
}

@test "new mail is written with a rising number and the position moves" {
  run py "
s = {'history_id': '100', 'seq': 7}
print(w.look(Gmail([{'history': [added('a','t1','INBOX'), added('b','t2','INBOX')], 'historyId': '120'}]), s, EVENTS), s['history_id'], s['seq'])
print([json.loads(l)['seq'] for l in open(EVENTS)])"
  [ "${lines[0]}" = "2 120 9" ]
  [ "${lines[1]}" = "[8, 9]" ]
}

@test "pages are followed to the end" {
  run py "
s = {'history_id': '100'}
print(w.look(Gmail([{'history': [added('a','t1','INBOX')], 'nextPageToken': 'p2'}, {'history': [added('b','t2','INBOX')], 'historyId': '130'}]), s, EVENTS), s['history_id'])"
  [ "$output" = "2 130" ]
}

@test "a failed look keeps the position, so the mail comes back" {
  run py "
s = {'history_id': '100'}
class Broken(Gmail):
    def list(self, **kw):
        def go(): raise RuntimeError('network')
        return Run(go)
try: w.look(Broken(), s, EVENTS)
except RuntimeError: print('raised', s['history_id'])"
  [ "$output" = "raised 100" ]
}

@test "history Google threw away starts again from now" {
  run py "
s = {'history_id': '1'}
print(w.look(Gmail(gone=True), s, EVENTS), s['history_id'])"
  [[ "$output" == *"0 900"* ]]
}

@test "the list of mail stays short" {
  run py "
seq = w.append_events(EVENTS, [{'id': str(i), 'thread': 't'} for i in range(600)], 0)
rows = open(EVENTS).read().splitlines()
print(seq, len(rows), json.loads(rows[0])['seq'])"
  [ "$output" = "600 500 101" ]
}

@test "the watch is renewed a day before it ends, and only then" {
  run py "
push = {'topic': 'projects/p/topics/t'}
g = Gmail()
s = {'watch_topic': push['topic'], 'watch_expires': 10 * w.DAY}
w.renew_watch(g, s, push, 8 * w.DAY); print(len(g.watched))
w.renew_watch(g, s, push, 9.5 * w.DAY); print(len(g.watched), s['watch_expires'])
w.renew_watch(g, s, None, 0); print(len(g.watched))"
  [ "${lines[0]}" = "0" ]
  [ "${lines[1]}" = "1 1700000000" ]
  [ "${lines[2]}" = "1" ]
}

@test "without push it waits the set time; with push a message is acknowledged" {
  run py "
slept = []
w.wait_for_news(None, None, sleep=slept.append); print(slept == [w.POLL])
acked = []
class Pull:
    def projects(self): return self
    def subscriptions(self): return self
    def pull(self, subscription, body): return Run(lambda: {'receivedMessages': [{'ackId': 'x'}]})
    def acknowledge(self, subscription, body):
        acked.append(body['ackIds']); return Run(lambda: {})
w.wait_for_news(Pull(), {'subscription': 's'}, sleep=slept.append); print(acked, len(slept))"
  [ "${lines[0]}" = "True" ]
  [ "${lines[1]}" = "[['x']] 1" ]
}

@test "a push timeout looks at the mail at once; another failure waits first" {
  run py "
slept = []
class Pull:
    def __init__(self, err): self.err = err
    def projects(self): return self
    def subscriptions(self): return self
    def pull(self, subscription, body):
        def go(): raise self.err
        return Run(go)
w.wait_for_news(Pull(TimeoutError()), {'subscription': 's'}, sleep=slept.append); after_timeout = len(slept)
w.wait_for_news(Pull(ValueError()), {'subscription': 's'}, sleep=slept.append); print(after_timeout, len(slept))"
  [ "${lines[-1]}" = "0 1" ]
}
