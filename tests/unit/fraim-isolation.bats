#!/usr/bin/env bats
# bin/fraim-isolation (the server's space isolation rules) with a fake iptables that keeps
# its rules in a file: the reply-safe DOCKER-USER rule, repair of the old rule, no gap.

setup() {
  ISO="$BATS_TEST_DIRNAME/../../bin/fraim-isolation"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin"
  export RULES="$T/rules" LOG="$T/log"
  : > "$RULES"
  cat > "$T/bin/iptables" <<'EOF'
#!/usr/bin/env bash
# Fake iptables: -w ignored; -L CHAIN lists; -C/-I/-D check, insert and delete "CHAIN spec".
# FAIL_INSERT=1 makes every insert fail (a held lock or a missing module).
[ "${1:-}" = -w ] && shift
op="$1" chain="$2"; shift 2
printf '%s %s %s\n' "$op" "$chain" "$*" >> "$LOG"
line="$chain $*"
case "$op" in
  -L) exit 0 ;;
  -C) grep -qxF -- "$line" "$RULES" ;;
  -I) [ -z "${FAIL_INSERT:-}" ] || exit 4
      { printf '%s\n' "$line"; cat "$RULES"; } > "$RULES.new" && mv "$RULES.new" "$RULES" ;;
  -D) grep -qxF -- "$line" "$RULES" || exit 1
      awk -v l="$line" 'done || $0 != l { print; next } { done = 1 }' "$RULES" > "$RULES.new" && mv "$RULES.new" "$RULES" ;;
esac
EOF
  chmod +x "$T/bin/iptables"
  export PATH="$T/bin:$PATH"
  OLD="DOCKER-USER -s 172.30.0.0/16 -m conntrack --ctstate DNAT -j DROP"
  NEW="DOCKER-USER -s 172.30.0.0/16 -m conntrack --ctstate DNAT --ctdir ORIGINAL -j DROP"
}

@test "a fresh server gets the reply-safe rule for every space network, and the INPUT rules" {
  run "$ISO"
  [ "$status" -eq 0 ]
  for net in 172.29.0.0/16 172.30.0.0/16 172.31.0.0/16; do
    grep -qxF "DOCKER-USER -s $net -m conntrack --ctstate DNAT --ctdir ORIGINAL -j DROP" "$RULES"
  done
  [ "$(grep -c '^INPUT ' "$RULES")" -eq 6 ]
  [ "$(grep -cxF "$OLD" "$RULES")" -eq 0 ]
}

@test "the old rule that drops replies is removed, after the new one is in place" {
  printf '%s\n%s\n' "$OLD" "$OLD" > "$RULES"
  run "$ISO"
  [ "$status" -eq 0 ]
  [ "$(grep -cxF "$OLD" "$RULES")" -eq 0 ]
  grep -qxF "$NEW" "$RULES"
  # No gap in isolation: the insert of the new rule comes before the first delete.
  ins="$(grep -n "^-I DOCKER-USER -s 172.30.0.0/16" "$LOG" | head -1 | cut -d: -f1)"
  del="$(grep -n "^-D DOCKER-USER -s 172.30.0.0/16" "$LOG" | head -1 | cut -d: -f1)"
  [ "$ins" -lt "$del" ]
}

@test "running it again adds nothing twice" {
  "$ISO"
  before="$(wc -l < "$RULES")"
  run "$ISO"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$RULES")" -eq "$before" ]
}

@test "when the new rule cannot be added, the old rule stays and the script fails" {
  printf '%s\n' "$OLD" > "$RULES"
  FAIL_INSERT=1 run "$ISO"
  [ "$status" -eq 1 ]
  grep -qxF "$OLD" "$RULES"
  [[ "$output" == *"the old rule stays"* ]]
}

@test "an INPUT rule that cannot be added makes the script fail" {
  FAIL_INSERT=1 run "$ISO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not add the rule: INPUT"* ]]
}
