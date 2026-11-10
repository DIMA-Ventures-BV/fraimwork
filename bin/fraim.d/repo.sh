# shellcheck shell=bash disable=SC2034,SC2154
load_group secret

# --- repo: GitHub through the secrets proxy ------------------------------------------
cmd_repo() {
  parse_flags "$@"
  local action="${POSITIONAL[0]:-list}" repo="${POSITIONAL[1]:-}"
  local usage_line="fraim repo token [--stdin] | add OWNER/REPO [--dir DIR] | list [--json] | setup [--git-name N --git-email E]"
  load_config
  case "$action" in
    token)
      local pat url
      url="$(github_token_url "$(flag owner)")"
      need_secret_input "Make a GitHub token for this space: open $url (the name, lifetime and permissions are filled in). Check that Resource owner is the account or organization that owns the repositories, choose 'Only select repositories' with the repositories this space needs, click Generate token and copy it. Then in your own Terminal app (not in the Claude chat) run: fraim repo token$(space_hint)  and paste it. Then tell Claude 'done'."
      [ -n "$(flag stdin)" ] || { open_url "$url"; say "Check Resource owner, choose the repositories, click Generate token and copy it."; }
      pat="$(read_secret_input "Paste the GitHub token")"
      case "$pat" in github_pat_*|ghp_*|gho_*|ghu_*|ghs_*) ;; *) usage "that does not look like a GitHub token (github_pat_... or ghp_...)" ;; esac
      secret_define github https://github.com Authorization 'Basic %s'
      secret_define github-api https://api.github.com Authorization 'Bearer %s'
      secret_define github-mcp https://api.githubcopilot.com Authorization 'Bearer %s'
      printf 'x-access-token:%s' "$pat" | base64 | tr -d '\n' | secret_store github
      printf '%s' "$pat" | secret_store github-api
      printf '%s' "$pat" | secret_store github-mcp
      workspace_ssh "fraim-repo setup $(git_identity_args) && fraim-connect proxied github-mcp /mcp/ >/dev/null && fraim-connect reload >/dev/null" \
        || die "the token is stored, but setting up git in space $FRAIM_SPACE failed; run: fraim repo setup$(space_hint)"
      say "GitHub token stored for space $FRAIM_SPACE (git, the GitHub API and the GitHub MCP server use it through the secrets proxy)."
      ;;
    setup) workspace_ssh "fraim-repo setup $(git_identity_args)" ;;
    add)
      [ -n "$repo" ] || usage "$usage_line"
      secret_has_key github || human "Space $FRAIM_SPACE has no GitHub token yet. Claude runs: fraim repo token$(space_hint) (it explains how to make one)."
      local dir_arg=""
      [ -z "$(flag dir)" ] || dir_arg="--dir $(printf '%q' "$(flag dir)")"
      workspace_ssh "fraim-repo add $(printf '%q' "$repo") $dir_arg"
      ;;
    list) if [ -n "$(flag json)" ]; then workspace_ssh 'fraim-repo list --json'; else workspace_ssh 'fraim-repo list'; fi ;;
    *) usage "$usage_line" ;;
  esac
}
# GitHub's new fine-grained token page, filled in through its URL parameters.
github_token_url() {  # [OWNER]
  local name="fraim-${FRAIM_TARGET}-${FRAIM_SPACE}"
  local url="https://github.com/settings/personal-access-tokens/new?name=$name&description=fraim+space+$FRAIM_SPACE+on+$FRAIM_HOST&expires_in=90&contents=write&pull_requests=write"
  [ -z "${1:-}" ] || url="$url&target_name=$1"
  printf '%s' "$url"
}
# --name/--email for git inside the space: flags, else this laptop's git identity.
git_identity_args() {
  local name email
  name="$(flag git-name)"; name="${name:-$(git config --global user.name 2>/dev/null || true)}"
  email="$(flag git-email)"; email="${email:-$(git config --global user.email 2>/dev/null || true)}"
  [ -z "$name" ] || printf -- '--name %q ' "$name"
  [ -z "$email" ] || printf -- '--email %q' "$email"
}
