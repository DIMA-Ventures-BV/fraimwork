# shellcheck shell=bash disable=SC2034,SC2154
load_group repo mirror

# --- project: a repo's .fraim folder on this space (docs/projects.md) --------------------
# The plan names one commit, and only that commit is installed after the user's yes.
cmd_project() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-list}" target="${POSITIONAL[1]:-}" yes dry commit to all
  yes="$(flag yes)"; dry="$(flag dry-run)"; commit="$(flag commit)"; to="$(flag to)"; all="$(flag all)"
  local usage_line="fraim project add OWNER/REPO [--dry-run] [--yes --commit SHA] | update REPO [--dry-run] [--yes --commit SHA] | on REPO ITEM...|--all | list | export ITEM... --to DIR/.fraim"
  local rest=() i
  for ((i = 2; i < ${#POSITIONAL[@]}; i++)); do rest+=("${POSITIONAL[$i]}"); done
  load_config
  case "$action" in
    list) workspace_ssh 'fraim-project list' ;;
    on)
      [ -n "$target" ] || usage "$usage_line"
      [ -z "$all" ] || rest+=(--all)
      [ "${#rest[@]}" -gt 0 ] || usage "$usage_line"
      workspace_ssh "fraim-project on $(printf '%q ' "$target" "${rest[@]}")"
      ;;
    export)
      [ -n "$target" ] && [ -n "$to" ] || usage "$usage_line"
      mkdir -p "$to"
      workspace_ssh "fraim-project export $(printf '%q ' "$target" ${rest[@]+"${rest[@]}"})" < /dev/null | tar -xf - -C "$to" \
        || die "could not export; nothing usable was written to $to"
      say "Wrote to $to. Check the files for private details, then commit them to the repo."
      ;;
    add|update)
      [ -n "$target" ] || usage "$usage_line"
      local name="${target#*/}" q again tmp rc
      name="${name%.git}"
      q="$(printf '%q' "$name")"
      if [ "$action" = add ]; then
        printf '%s' "$target" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || usage "$usage_line"
        cmd_repo add "$target" < /dev/null
      fi
      again="fraim project $action $target --yes"
      tmp="$(mktemp)"
      if [ -z "$yes" ] || [ -n "$dry" ]; then
        commit="$(workspace_ssh "fraim-project head $q" < /dev/null)" || { rm -f "$tmp"; die "could not read the default branch of $name"; }
        workspace_ssh "fraim-project plan $q $commit" < /dev/null || { rm -f "$tmp"; exit 1; }
        workspace_ssh "fraim-project needs $q $commit" < /dev/null > "$tmp" || { rm -f "$tmp"; exit 1; }
        if [ -s "$tmp" ]; then
          say ""; say "This project also needs:"
          set +e; (cmd_mirror "$tmp" --dry-run); rc=$?; set -e
          [ "$rc" -eq 0 ] || { rm -f "$tmp"; exit "$rc"; }
        fi
        rm -f "$tmp"
        [ -z "$dry" ] || return 0
        human "Show the user the plan above. New leads and automations arrive switched off, updates change what already runs. A repo's automation can run scripts on the server, and a needs line can send a key to a host. On yes, Claude runs: $again --commit $commit$(space_hint)"
      fi
      [ -n "$commit" ] || { rm -f "$tmp"; usage "--yes needs the --commit from the plan: $again --commit SHA"; }
      workspace_ssh "fraim-project apply $q $(printf '%q' "$commit")" < /dev/null || { rm -f "$tmp"; exit 1; }
      workspace_ssh "fraim-project needs $q $(printf '%q' "$commit")" < /dev/null > "$tmp" || { rm -f "$tmp"; exit 1; }
      rc=0
      if [ -s "$tmp" ]; then
        set +e; (MIRROR_RERUN="$again --commit $commit$(space_hint)" cmd_mirror "$tmp" --yes); rc=$?; set -e
      fi
      rm -f "$tmp"
      [ "$rc" -eq 0 ] || exit "$rc"
      say "Switch items on with: fraim project on $name ITEM...|--all$(space_hint)"
      ;;
    *) usage "$usage_line" ;;
  esac
}
