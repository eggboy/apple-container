#!/usr/bin/env bash
# hub-login — log Apple `container` in to Docker Hub (docker.io).  (bash version)
#
# `container` has no credential-helper support; it only reads static logins from
# the macOS Keychain (security domain com.apple.container.registry, one item per
# host). This stores a Docker Hub personal access token (or password) via
# `container registry login`, which validates it against the registry first.
# Unlike Artifact Registry tokens, Docker Hub tokens do not expire unless you
# gave them an expiry, so this normally only needs to run once per machine.
#
# Works with the stock macOS /bin/bash 3.2 as well as Homebrew bash 5.x.
#
# Install:
#   echo 'source /path/to/hub-login.bash' >> ~/.bashrc    # or ~/.bash_profile
# The file can also be executed directly:  ./hub-login.bash -u <user>
#
# Run `hub-login --help` for usage.

function hub-login() {
  # Everything is initialised so the function is safe under `set -u` in any bash.
  local username='' tokenfile='' token='' out='' host='docker.io'
  local -i dry_run=0

  while (( $# )); do
    case "${1}" in
      -u|--username)
        [[ -n "${2-}" ]] || { printf '%s\n' "hub-login: ${1} requires a value (try -h)" >&2; return 2; }
        username=${2}; shift 2 ;;
      --username=*) username=${1#*=}; shift ;;
      -t|--token-file)
        [[ -n "${2-}" ]] || { printf '%s\n' "hub-login: ${1} requires a value (try -h)" >&2; return 2; }
        tokenfile=${2}; shift 2 ;;
      --token-file=*) tokenfile=${1#*=}; shift ;;
      -n|--dry-run) dry_run=1; shift ;;
      -V|--version) printf '%s\n' '1.0.0'; return 0 ;;
      -h|--help)
        cat <<'EOF'
Usage: hub-login [OPTIONS] [USERNAME]

Log Apple `container` in to Docker Hub (docker.io).

Arguments:
  USERNAME               Docker Hub username; for an organization access token,
                         the organization name. Same as -u. [default: $HUB_LOGIN_USER]

Options:
  -u, --username <name>  Docker Hub username (see USERNAME)
  -t, --token-file <f>   Read the access token (or password) from a file;
                         use - to read it from stdin
  -n, --dry-run          Show what would be done, without prompting or logging in
  -h, --help             Show this help
  -V, --version          Show version

The token is never accepted as a flag, so it cannot leak into shell history or
`ps`. It is taken from, in order: --token-file, stdin when stdin is not a
terminal, or a hidden interactive prompt.

Environment:
  HUB_LOGIN_USER         Default username

Exit status:
  0  logged in                 2  usage error
  1  login failed              127 container not found

Examples:
  hub-login -u jayleeg                    # prompts for the token (input hidden)
  pbpaste | hub-login -u jayleeg          # token from the clipboard via stdin
  hub-login -u jayleeg -t ~/.config/docker-hub-token
  security find-generic-password -s docker-hub -w | hub-login -u jayleeg
  HUB_LOGIN_USER=jayleeg hub-login -n     # dry run

Create a token at https://app.docker.com/settings/personal-access-tokens with
"Read & Write" access to push. Accounts with 2FA must use a token, not the
password. Docs: https://docs.docker.com/security/access-tokens/
EOF
        return 0 ;;
      --) shift; break ;;
      -*) printf '%s\n' "hub-login: unknown option: ${1} (try -h)" >&2; return 2 ;;
      *)  break ;;
    esac
  done

  if (( $# )); then
    if [[ -n "${username}" ]]; then
      printf '%s\n' "hub-login: username given twice (${username} and ${1})" >&2
      return 2
    fi
    username=${1}; shift
  fi
  if (( $# )); then
    printf '%s\n' "hub-login: unexpected argument: ${1} (try -h)" >&2
    return 2
  fi
  [[ -n "${username}" ]] || username=${HUB_LOGIN_USER:-}
  if [[ -z "${username}" ]]; then
    printf '%s\n' "hub-login: no username; pass -u <name> or set HUB_LOGIN_USER (try -h)" >&2
    return 2
  fi

  if ! command -v container >/dev/null 2>&1; then
    printf '%s\n' "hub-login: 'container' CLI not found in PATH" \
      "  Install it from https://github.com/apple/container/releases" >&2
    return 127
  fi

  # Validate the token source early; in dry-run mode never read or prompt.
  if [[ -n "${tokenfile}" && "${tokenfile}" != - ]]; then
    if [[ ! -r "${tokenfile}" ]]; then
      printf '%s\n' "hub-login: cannot read token file: ${tokenfile}" >&2
      return 1
    fi
  elif [[ "${tokenfile}" == - && -t 0 ]]; then
    printf '%s\n' "hub-login: -t - expects the token on stdin (try -h)" >&2
    return 2
  fi

  if (( dry_run )); then
    printf '%s\n' "hub-login: would log in to ${host} as ${username}"
    return 0
  fi

  if [[ -n "${tokenfile}" && "${tokenfile}" != - ]]; then
    token=$(<"${tokenfile}")
  elif [[ -n "${tokenfile}" || ! -t 0 ]]; then
    token=$(cat)
  else
    printf '%s' "Docker Hub access token for ${username} (input hidden): " >&2
    IFS= read -rs token || true          # Ctrl-D -> empty token -> clear error below, even under set -e
    printf '\n' >&2
  fi
  token=${token//[[:space:]]/}
  if [[ -z "${token}" ]]; then
    printf '%s\n' "hub-login: empty token (try -h)" >&2
    return 1
  fi

  # `printf` is a builtin, so the token never shows up in `ps` output.
  if out=$(printf '%s' "${token}" | container registry login --username "${username}" --password-stdin "${host}" 2>&1); then
    # container stores Docker Hub logins under its resolved name, registry-1.docker.io.
    printf '%s\n' "hub-login: logged in to ${host} as ${username} (listed as registry-1.docker.io in 'container registry list')" \
      "  Push with: container image push ${host}/${username}/<image>:<tag>"
    return 0
  fi

  printf '%s\n' "${out}" >&2
  # Docker Hub signals bad credentials by answering the token exchange at
  # auth.docker.io with 401 + its own challenge; container reports that as
  # "refusing insecure credential exchange: ... issued its own authentication challenge".
  if [[ "${out}" == *'issued its own authentication challenge'* || "${out}" == *401* || "${out}" == *[Uu]nauthorized* ]]; then
    printf '%s\n' "hub-login: Docker Hub rejected the credentials. Use a personal access token (required with 2FA)" \
      "  and your Docker Hub username, not the e-mail: https://app.docker.com/settings/personal-access-tokens" >&2
  fi
  printf '%s\n' "hub-login: login to ${host} failed" >&2
  return 1
}

# When executed as a script (not sourced), run with strict mode and pass args through.
# (Strict mode is deliberately not applied when sourced: it would change the caller's shell.)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  hub-login "$@"
fi
