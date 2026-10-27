#!/usr/bin/env bash
# ar-login — log Apple `container` in to Google Artifact Registry.  (bash version)
#
# `container` has no credential-helper support; it only reads static logins from
# the macOS Keychain (security domain com.apple.container.registry, one item per
# host). This mints a short-lived gcloud access token (~1h) and stores it via
# `container registry login`, which validates it against the registry first.
#
# Works with the stock macOS /bin/bash 3.2 as well as Homebrew bash 5.x.
#
# Install:
#   echo 'source /path/to/ar-login.bash' >> ~/.bashrc    # or ~/.bash_profile
# The file can also be executed directly:  ./ar-login.bash us
#
# Run `ar-login --help` for usage. Requires container >= 1.6.0 (older builds
# reject Artifact Registry's /v2/ auth challenge).

function ar-login() {
  # Everything is initialised so the function is safe under `set -u` in any bash
  # (bash 5 treats a declared-but-unassigned array as unset; bash 3.2 errors on
  # "${empty[@]}", which is why empty arrays are never expanded below).
  local account='' keyfile='' host='' user='' secret='' out='' code='' joined=''
  local -i dry_run=0
  local -a hosts=() failed=() gcloud_args=()

  while (( $# )); do
    case "${1}" in
      -a|--account)
        [[ -n "${2-}" ]] || { printf '%s\n' "ar-login: ${1} requires a value (try -h)" >&2; return 2; }
        account=${2}; shift 2 ;;
      --account=*) account=${1#*=}; shift ;;
      -k|--key)
        [[ -n "${2-}" ]] || { printf '%s\n' "ar-login: ${1} requires a value (try -h)" >&2; return 2; }
        keyfile=${2}; shift 2 ;;
      --key=*) keyfile=${1#*=}; shift ;;
      -n|--dry-run) dry_run=1; shift ;;
      -V|--version) printf '%s\n' '1.0.0'; return 0 ;;
      -h|--help)
        cat <<'EOF'
Usage: ar-login [OPTIONS] [HOST|REGION ...]

Log Apple `container` in to Google Artifact Registry.

Arguments:
  HOST|REGION            Registry host, or a region/multi-region shorthand that
                         is expanded to <region>-docker.pkg.dev (e.g. "us",
                         "asia-southeast1"). [default: $AR_LOGIN_HOSTS, or
                         asia-southeast1-docker.pkg.dev if unset]

Options:
  -a, --account <email>  gcloud account to mint the access token for
  -k, --key <file>       Service-account key file instead of a gcloud token
                         (long-lived; username _json_key_base64). Use - to read
                         the key from stdin.
  -n, --dry-run          Show which hosts would be logged in to, without doing it
  -h, --help             Show this help
  -V, --version          Show version

Environment:
  AR_LOGIN_HOSTS         Space-separated default hosts/regions

Exit status:
  0  all hosts logged in      2  usage error
  1  a login failed           127 container/gcloud not found

Examples:
  ar-login                                 # default host
  ar-login us europe-west1                 # several regions at once
  ar-login -a me@example.com us            # token for a specific gcloud account
  ar-login -k ~/sa-key.json us             # service-account key
  gcloud secrets versions access latest --secret=sa-key | ar-login -k - us
  ar-login -n us                           # dry run

Without -k the stored credential is a gcloud OAuth access token that expires in
about an hour; just run ar-login again to refresh it.
Docs: https://cloud.google.com/artifact-registry/docs/docker/authentication
EOF
        return 0 ;;
      --) shift; break ;;
      -*) printf '%s\n' "ar-login: unknown option: ${1} (try -h)" >&2; return 2 ;;
      *)  break ;;
    esac
  done

  hosts=("$@")
  # `read -a` splits on whitespace without globbing (bash has no ${=var}).
  (( ${#hosts[@]} )) || read -r -a hosts <<< "${AR_LOGIN_HOSTS:-asia-southeast1-docker.pkg.dev}"
  if (( ${#hosts[@]} == 0 )); then
    printf '%s\n' "ar-login: no hosts given and AR_LOGIN_HOSTS is blank (try -h)" >&2
    return 2
  fi

  if ! command -v container >/dev/null 2>&1; then
    printf '%s\n' "ar-login: 'container' CLI not found in PATH" \
      "  Install it from https://github.com/apple/container/releases (1.6.0 or newer)" >&2
    return 127
  fi

  # Resolve the credential. In dry-run mode only validate; never read or mint.
  if [[ -n "${keyfile}" ]]; then
    user=_json_key_base64
    if [[ "${keyfile}" == - ]]; then
      if [[ -t 0 ]]; then
        printf '%s\n' "ar-login: -k - expects the key file on stdin (try -h)" >&2
        return 2
      fi
      if (( ! dry_run )); then
        secret=$(base64) || return 1
      fi
    else
      if [[ ! -r "${keyfile}" ]]; then
        printf '%s\n' "ar-login: cannot read key file: ${keyfile}" >&2
        return 1
      fi
      if (( ! dry_run )); then
        secret=$(base64 < "${keyfile}") || return 1
      fi
    fi
    secret=${secret//$'\n'/}            # strip line wrapping without a pipe (no pipefail needed)
  else
    user=oauth2accesstoken
    if ! command -v gcloud >/dev/null 2>&1; then
      printf '%s\n' "ar-login: 'gcloud' not found in PATH (or pass -k KEY.json)" \
        "  Install it from https://cloud.google.com/sdk/docs/install" >&2
      return 127
    fi
    if (( ! dry_run )); then
      gcloud_args=(auth print-access-token)
      [[ -n "${account}" ]] && gcloud_args+=(--account="${account}")
      if ! secret=$(gcloud "${gcloud_args[@]}"); then
        printf '%s\n' "ar-login: gcloud could not mint an access token" \
          "  Try: gcloud auth login${account:+ ${account}}   (or pass -k KEY.json)" >&2
        return 1
      fi
      if [[ -z "${secret}" ]]; then
        printf '%s\n' "ar-login: gcloud returned an empty token" >&2
        return 1
      fi
    fi
  fi

  for host in "${hosts[@]}"; do
    # Bare region / multi-region -> Artifact Registry Docker host.
    [[ "${host}" == *.* ]] || host="${host}-docker.pkg.dev"

    if (( dry_run )); then
      printf '%s\n' "ar-login: would log in to ${host} as ${user}"
      continue
    fi

    # Validate early: *-docker.pkg.dev is wildcard DNS, so a mistyped region
    # answers with a redirect instead of an auth challenge, and `container`
    # would store the credential unverified. A real registry answers /v2/ with 401.
    if [[ "${host}" == *.pkg.dev ]] && command -v curl >/dev/null 2>&1; then
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}/v2/" 2>/dev/null) || code=000
      if [[ -z "${code}" || "${code}" == 000 ]]; then
        printf '%s\n' "ar-login: could not reach https://${host}/v2/ (check network/VPN, or the host spelling)" >&2
        failed+=("${host}")
        continue
      elif [[ "${code}" != 401 ]]; then
        printf '%s\n' "ar-login: ${host} did not answer like a registry (HTTP ${code}); check the region/host spelling" >&2
        failed+=("${host}")
        continue
      fi
    fi

    # `printf` is a builtin, so the secret never shows up in `ps` output.
    if out=$(printf '%s' "${secret}" | container registry login --username "${user}" --password-stdin "${host}" 2>&1); then
      if [[ "${user}" == oauth2accesstoken ]]; then
        printf '%s\n' "ar-login: logged in to ${host} as ${user} (token expires in ~1h; re-run to refresh)"
      else
        printf '%s\n' "ar-login: logged in to ${host} as ${user}"
      fi
      continue
    fi

    failed+=("${host}")
    printf '%s\n' "${out}" >&2
    if [[ "${out}" == *'cannot parse service from WWW-Authenticate header'* ]]; then
      printf '%s %s %s\n' "ar-login: hint: Artifact Registry omits 'service=' from its /v2/ auth challenge and" \
        "container < 1.6.0 rejects that (apple/containerization#940)." \
        "Upgrade container: https://github.com/apple/container/releases" >&2
    fi
  done

  if (( ${#failed[@]} )); then
    printf -v joined '%s, ' "${failed[@]}"
    printf '%s\n' "ar-login: failed for: ${joined%, }" >&2
    return 1
  fi
}

# When executed as a script (not sourced), run with strict mode and pass args through.
# (Strict mode is deliberately not applied when sourced: it would change the caller's shell.)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  ar-login "$@"
fi
