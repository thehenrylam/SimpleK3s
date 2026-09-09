#!/bin/bash

# Provision, preview and tear down an infrastructure tier.
#
# A thin front door onto the Ansible playbooks, which stay the orchestration:
# they carry the tfvars gate, the wave ordering and the Terraform plumbing. This
# exists so an operator has ONE entry point rather than two — `sk3s` for a
# running cluster and `ansible-playbook` for the infrastructure under it — and
# so every infra run lands in the same log and history trail as everything else.
#
# WHY A NAMESPACE, not top-level verbs. `apply` already means something here:
# "stage manifests on the node that owns staging". A top-level `sk3s apply` that
# sometimes meant "tofu apply the whole tier" would collide on the word whose
# misreading is the expensive one. Tiers live under `infra`, so the two can
# never be confused, and a future tier that is neither cluster nor support slots
# in by adding one row below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLAYBOOK_DIR="${DEPLOYMENT_DIR}/playbooks"

EXIT_OK=0
EXIT_USAGE=2

# tier|summary
#
# The playbook for a tier and verb is <tier>_<verb>.yml. Deriving the filename
# rather than listing it keeps this table and the playbook directory from
# drifting: adding a tier is one row here plus its three playbooks, and a
# missing one is reported by name instead of failing obscurely inside Ansible.
TIERS=(
    "cluster|The K3s cluster: nodes, load balancer, bootstrap bucket"
    "support|Durable tier that survives cluster teardowns (idp, pvc, tailscale)"
)

# verb|summary
VERBS=(
    "plan|Preview changes without applying them"
    "apply|Create or update the tier"
    "destroy|Tear the tier down"
)

function field() {
    printf '%s' "${1%%|*}"
}

function rest() {
    printf '%s' "${1#*|}"
}

function usage() {
    local _STATUS="${1:-${EXIT_USAGE}}" _ENTRY
    # Explicit --help goes to stdout and exits 0; usage shown because the caller
    # got it wrong goes to stderr, so a pipeline is not fed a help screen.
    if (( _STATUS == EXIT_OK )); then exec 3>&1; else exec 3>&2; fi
    {
        echo "Usage: sk3s infra <tier> <verb> [ansible-playbook args...]"
        echo ""
        echo "Tiers:"
        for _ENTRY in "${TIERS[@]}"; do
            printf '  %-9s %s\n' "$(field "${_ENTRY}")" "$(rest "${_ENTRY}")"
        done
        echo ""
        echo "Verbs:"
        for _ENTRY in "${VERBS[@]}"; do
            printf '  %-9s %s\n' "$(field "${_ENTRY}")" "$(rest "${_ENTRY}")"
        done
        cat <<'EOF'

Examples:
  sk3s infra cluster plan
  sk3s infra cluster apply
  sk3s infra cluster destroy

  sk3s infra support destroy --limit '!idp'
      Tears down every support root EXCEPT the IdP — i.e. pvc and tailscale.
      This is usually the one you want. Cognito stays inside the free tier on
      monthly active users, but destroying and recreating the pool forces every
      user to register again, and each re-registration spends MAU budget. Alone
      that is an annoyance; with a handful of internal users it can push the
      account past the free tier outright. Leave the IdP standing unless you
      specifically mean to replace it.

  sk3s infra support apply --limit pvc
      One root. Hosts are named idp, pvc and tailscale (see inventory.yml), and
      --limit takes any Ansible host pattern.

  sk3s infra cluster apply -e verify_after_apply=false
      Skip the post-apply health check. `cluster apply` verifies afterwards
      with 15 attempts 30s apart, so a cluster that comes up unhealthy holds
      the terminal for ~7 minutes before failing. When you already know it will
      fail — mid-repair, or iterating on a broken deploy — this returns as soon
      as the infrastructure is in place. Run `sk3s status` when you want the
      verdict.

Ordering: apply support before cluster; destroy cluster before support. The
cluster tier reads Parameter Store values the support tier owns, so tearing
support down first strands the cluster mid-destroy.

Everything after <verb> is passed through to ansible-playbook untouched.
Configuration comes from group_vars/all.yml, so these verbs take no profile.
EOF
    } >&3
    exec 3>&-
    exit "${_STATUS}"
}

function known() {
    # known <value> <table-entry>...
    local _WANT="${1}" _ENTRY
    shift
    for _ENTRY in "$@"; do
        [[ "$(field "${_ENTRY}")" == "${_WANT}" ]] && return 0
    done
    return 1
}

function names_of() {
    local _ENTRY _OUT=""
    for _ENTRY in "$@"; do
        _OUT+="$(field "${_ENTRY}"), "
    done
    printf '%s' "${_OUT%, }"
}

TIER="${1:-}"
case "${TIER}" in
    "")              usage "${EXIT_USAGE}" ;;
    -h|--help|help)  usage "${EXIT_OK}" ;;
esac
shift

if ! known "${TIER}" "${TIERS[@]}"; then
    echo "Error: unknown tier '${TIER}'. Known tiers: $(names_of "${TIERS[@]}")." >&2
    echo "" >&2
    usage "${EXIT_USAGE}"
fi

VERB="${1:-}"
case "${VERB}" in
    "")              echo "Error: '${TIER}' needs a verb." >&2 ; echo "" >&2 ; usage "${EXIT_USAGE}" ;;
    -h|--help|help)  usage "${EXIT_OK}" ;;
esac
shift

if ! known "${VERB}" "${VERBS[@]}"; then
    echo "Error: unknown verb '${VERB}'. Known verbs: $(names_of "${VERBS[@]}")." >&2
    echo "" >&2
    usage "${EXIT_USAGE}"
fi

PLAYBOOK="${PLAYBOOK_DIR}/${TIER}_${VERB}.yml"
if [[ ! -f "${PLAYBOOK}" ]]; then
    # A tier listed above with no playbook on disk is a packaging error, not an
    # operator error, so it says which file is missing rather than "unknown".
    echo "Error: no playbook for '${TIER} ${VERB}' (expected ${PLAYBOOK})." >&2
    exit 1
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "Error: ansible-playbook not found. Install the standard toolchain:" >&2
    echo "  ./toolchain/tc_standard_macos_install.sh" >&2
    exit 1
fi

# Run from the deployment root: the playbooks resolve inventory.yml,
# group_vars/ and the terraform roots relative to it.
cd "${DEPLOYMENT_DIR}"
exec ansible-playbook "${PLAYBOOK}" "$@"
