#!/usr/bin/env bash
# tf — Terraform wrapper with SSO auth, workspace management, and env-aware plan/apply.
#
# Usage:
#   tf <env> [mode] [extra-tf-args...]
#
# Modes:
#   plan       terraform plan (default for PRs)
#   apply      terraform apply -auto-approve
#   refresh    terraform refresh
#   <any>      passed through to terraform (e.g. output, state, console)
#
# Configuration:
#   Place a .tf.conf file in the repo root (next to terraform/) to override defaults.
#   See README for all available options.
#
set -euo pipefail

ENV="${1:-}"
MODE="${2:-apply}"

if [[ -z "${ENV}" ]]; then
  echo "🚨 Usage: tf <env> [plan|apply|refresh|output|state|...]"
  echo "   Examples:"
  echo "     tf dev plan"
  echo "     tf prod apply"
  echo "     tf dev output"
  exit 1
fi

# --- Locate repo root ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Walk up from SCRIPT_DIR to find the repo root (contains terraform/ dir)
find_repo_root() {
  local dir="${SCRIPT_DIR}"
  while [[ "${dir}" != "/" ]]; do
    if [[ -d "${dir}/terraform" ]]; then
      echo "${dir}"
      return
    fi
    dir="$(dirname "${dir}")"
  done
  # Fallback: assume script is in tools/ or root
  echo "${SCRIPT_DIR}"
}

REPO_ROOT="$(find_repo_root)"
TF_DIR="${REPO_ROOT}/terraform"

# --- Defaults (overridable via .tf.conf) ---
TF_AWS_PROFILE="${TF_AWS_PROFILE:-}"
TF_ALLOWED_ENVS="${TF_ALLOWED_ENVS:-dev prod}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-}"
TF_AWS_REGION="${TF_AWS_REGION:-us-east-1}"

# --- Load project config (.tf.conf) ---
CONF_FILE="${REPO_ROOT}/.tf.conf"
if [[ -f "${CONF_FILE}" ]]; then
  while IFS='=' read -r key value || [[ -n "${key}" ]]; do
    key="${key%%#*}"      # strip inline comments
    key="${key// /}"       # strip spaces
    value="${value%%#*}"
    value="${value## }"    # trim leading space
    value="${value%% }"    # trim trailing space
    # Strip surrounding quotes
    if [[ "${value}" == \"*\" ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "${value}" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    case "${key}" in
      aws_profile)     TF_AWS_PROFILE="${value}" ;;
      allowed_envs)    TF_ALLOWED_ENVS="${value}" ;;
      state_bucket)    TF_STATE_BUCKET="${value}" ;;
      aws_region)      TF_AWS_REGION="${value}" ;;
    esac
  done < "${CONF_FILE}"
fi

# --- Load .env secrets (TF_VAR_* only, no shell execution) ---
if [[ -f "${REPO_ROOT}/.env" ]]; then
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    if [[ "${line}" == TF_VAR_*=* ]]; then
      key="${line%%=*}"
      if [[ ! "${key}" =~ ^TF_VAR_[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "⚠️  Skipping .env line with invalid variable name: ${key}"
        continue
      fi
      value="${line#*=}"
      if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
      fi
      printf -v "${key}" '%s' "${value}"
      # shellcheck disable=SC2163
      export "${key}"
    fi
  done < "${REPO_ROOT}/.env"
fi

SKIP_INIT="${SKIP_INIT:-}"

# --- AWS profile handling ---
if [[ -n "${TF_AWS_PROFILE}" ]]; then
  export AWS_PROFILE="${AWS_PROFILE:-${TF_AWS_PROFILE}}"
fi

# Scrub raw creds so they don't override the profile
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
# Scrub TF_WORKSPACE — managed explicitly by this script
unset TF_WORKSPACE

if [[ -n "${AWS_PROFILE:-}" ]]; then
  echo "🔐 Using AWS profile: ${AWS_PROFILE}"

  echo "🔍 Checking AWS session for profile: ${AWS_PROFILE}..."
  if ! aws sts get-caller-identity --profile "${AWS_PROFILE}" >/dev/null 2>&1; then
    echo "⚠️  Session expired or not found for '${AWS_PROFILE}'."
    echo "🚀 Attempting automatic AWS SSO login..."
    if aws sso login --profile "${AWS_PROFILE}"; then
      echo "✅ Login successful!"
    else
      echo "❌ AWS SSO login failed. Check your config or internet connection."
      exit 1
    fi
  fi

  CALLER_JSON="$(aws sts get-caller-identity --output json)"
  ACCOUNT_ID="$(echo "$CALLER_JSON" | jq -r '.Account' 2>/dev/null || true)"
  ARN="$(echo "$CALLER_JSON" | jq -r '.Arn' 2>/dev/null || true)"
  echo "👤 Caller: ${ARN:-unknown}"
  echo "🏦 Account: ${ACCOUNT_ID:-unknown}"
fi

# --- Validations ---
if ! echo " ${TF_ALLOWED_ENVS} " | grep -q " ${ENV} "; then
  echo "❌ Invalid environment '${ENV}'. Allowed: ${TF_ALLOWED_ENVS}"
  exit 1
fi

TFVARS="${TF_DIR}/env/${ENV}/terraform.tfvars"
[[ -d "${TF_DIR}/env/${ENV}" ]] || { echo "❌ No env dir: ${TF_DIR}/env/${ENV}"; exit 1; }
[[ -f "${TFVARS}" ]]            || { echo "❌ Missing tfvars: ${TFVARS}"; exit 1; }

cd "${TF_DIR}"

# --- Init + workspace ---
BACKEND_CONF="${TF_DIR}/env/${ENV}/backend.conf"
echo "🔧 Initializing Terraform..."
echo "   📂 Root dir: ${TF_DIR}"

if [[ -z "$SKIP_INIT" ]]; then
  if [[ -f "${BACKEND_CONF}" ]]; then
    TF_WORKSPACE=default terraform init -reconfigure -backend-config="${BACKEND_CONF}" -input=false
  else
    TF_WORKSPACE=default terraform init -reconfigure -input=false
  fi

  echo "🪐 Using Terraform workspace: ${ENV}"
  terraform workspace new "${ENV}" 2>/dev/null || terraform workspace select "${ENV}"
else
  echo "🔧 SKIP_INIT set — skipping terraform init and workspace init"
fi

# --- Run pre-apply hook if present ---
PRE_APPLY_HOOK="${REPO_ROOT}/tools/tf-pre-apply"
if [[ "${MODE}" == "apply" && -x "${PRE_APPLY_HOOK}" ]]; then
  echo "🔨 Running pre-apply hook..."
  "${PRE_APPLY_HOOK}" "${ENV}"
fi

# --- Plan / Apply / Refresh / passthrough ---
COMMON_TFVARS="${TF_DIR}/env/common.tfvars"
VAR_FILES=()
[[ -f "${COMMON_TFVARS}" ]] && VAR_FILES+=(-var-file="${COMMON_TFVARS}")
VAR_FILES+=(-var-file="${TFVARS}")

SHOW_OUTPUTS=false
if [[ "${MODE}" == "--refresh" || "${MODE}" == "refresh" || "${MODE}" == "apply" ]]; then
  SHOW_OUTPUTS=true
fi

case "${MODE}" in
  --plan|plan)
    echo "📝 Running terraform plan..."
    terraform plan "${VAR_FILES[@]}" "${@:3}"
    ;;
  --refresh|refresh)
    echo "🔄 Running terraform refresh..."
    terraform refresh "${VAR_FILES[@]}" "${@:3}"
    ;;
  apply)
    echo "🚀 Running terraform apply..."
    terraform apply -auto-approve "${VAR_FILES[@]}" "${@:3}"
    ;;
  *)
    echo "🛠️  Running terraform ${MODE}..."
    terraform "${MODE}" "${@:3}"
    ;;
esac

if [[ "$SHOW_OUTPUTS" == true ]]; then
  echo ""
  echo "📦 Terraform outputs:"
  terraform output
fi

echo ""
echo "🎉 Terraform ${MODE/--/} complete for env: ${ENV}"
