#!/usr/bin/env bash

# Author: DylanC


set -euo pipefail
trap 'code=$?; echo "[ERR] Script failed at line $LINENO (exit $code)" >&2' ERR
export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/cfn-awsconfcheck.yaml"
DIST_DIR="${PROJECT_ROOT}/dist-prebuilt"

REGION=""
STACK_NAME=""
BUCKET_NAME=""
REPORT_PREFIX="reports"
PROFILE=""
ARCH_MODE="auto"   # which arch to invoke (if both packaged)
INVOKE=1
LOG_TAIL=0
CLEANUP_MODE=0
FORCE=0
YES=0
DEBUG=0
RANDOM_BUCKET=0
PRECHECK=0
PRECHECK_CFN=0
INTERACTIVE=0
BINARY_DIR=""

ROLE_ARN=""
EXTERNAL_ID=""
SESSION_NAME="awsconfcheck-session"
REGIONS_ARG="all"
CONCURRENCY=10
AUTHORIZED_REGIONS_ONLY="false"
SINGLE_RUN=1

ENABLE_AMD64=true
ENABLE_ARM64=true
CODE_KEY_AMD64=""
CODE_KEY_ARM64=""

# Global variable to store accessible regions
ACCESSIBLE_REGIONS=()

print_usage() {
  cat <<EOF
Usage: $0 [options]

Core:
  --region <region>            (required) Deploy region
  --stack-name <name>          Stack name (default: awsconfcheck-<ts>)
  --bucket-name <name>         Use existing / custom bucket
  --random-bucket              Random suffix bucket naming
  --arch <amd64|arm64|auto>    Architecture to invoke (if both packaged)
  --binary-dir <dir>           Directory holding prebuilt binaries (default: ./dist under current directory)

Runtime / scan:
  --regions <list|all>
  --concurrency <n>
  --authorized-regions-only
  --loop                       Keep runtime loop (disable single-run)
  --no-invoke                  Skip invoke
  --log-tail                   Tail logs 30s after invoke

Validation:
  --precheck                   IAM simulate permission precheck only
  --precheck-cfn               Live CloudFormation create/update/delete precheck only

General:
  --profile <aws profile>
  --yes / --force              Assume yes to prompts
  --debug                      Bash trace
  --cleanup                    List stacks/functions/tagged buckets and interactively delete
  --help                       Show help

Expected binaries (any of the pattern variants):
  * awsconfcheck-amd64 OR awsconfcheck-x86_64 OR awsconfcheck-linux-amd64
  * awsconfcheck-arm64 OR awsconfcheck-aarch64 OR awsconfcheck-linux-arm64
You may provide only one; the absent architecture is disabled.
EOF
}

err() { echo "[ERR] $*" >&2; }
info() { echo "[INFO] $*" >&2; }
debug() { [[ $DEBUG -eq 1 ]] && echo "[DBG] $*" >&2; }
require() { command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }; }
now_ts() { date +%s; }
confirm() { local p="$1"; if [[ $YES -eq 1 || $FORCE -eq 1 ]]; then return 0; fi; read -r -p "$p [y/N]: " a || return 1; [[ $a =~ ^(y|Y|yes|YES)$ ]]; }
rand_suffix() { printf '%06x' $(( (RANDOM<<16) ^ RANDOM )); }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --region) REGION="$2"; shift 2;;
      --stack-name) STACK_NAME="$2"; shift 2;;
      --bucket-name) BUCKET_NAME="$2"; shift 2;;
      --random-bucket) RANDOM_BUCKET=1; shift;;
      --arch) ARCH_MODE="$2"; shift 2;;
      --binary-dir) BINARY_DIR="$2"; shift 2;;
      --role-arn) ROLE_ARN="$2"; shift 2;;
      --external-id) EXTERNAL_ID="$2"; shift 2;;
      --session-name) SESSION_NAME="$2"; shift 2;;
      --regions) REGIONS_ARG="$2"; shift 2;;
      --concurrency) CONCURRENCY="$2"; shift 2;;
      --authorized-regions-only) AUTHORIZED_REGIONS_ONLY="true"; shift;;
      --loop) SINGLE_RUN=0; shift;;
      --no-invoke) INVOKE=0; shift;;
      --log-tail) LOG_TAIL=1; shift;;
      --precheck) PRECHECK=1; shift;;
      --precheck-cfn) PRECHECK_CFN=1; shift;;
  --cleanup) CLEANUP_MODE=1; shift;;
      --profile) PROFILE="$2"; shift 2;;
      --yes) YES=1; shift;;
      --force) FORCE=1; shift;;
      --debug) DEBUG=1; shift;;
      --help|-h) print_usage; exit 0;;
      *) err "Unknown arg: $1"; print_usage; exit 1;;
    esac
  done
}

# If any soft-deprecated role flags provided, we warn later in main.
ROLE_FLAGS_USED=0
[[ -n ${ROLE_ARN} || -n ${EXTERNAL_ID} || ${SESSION_NAME} != "awsconfcheck-session" ]] && ROLE_FLAGS_USED=1

aws_cmd() { local extra=(); [[ -n $PROFILE ]] && extra+=(--profile "$PROFILE"); [[ -n $REGION ]] && extra+=(--region "$REGION"); aws "${extra[@]}" "$@"; }

# Early validation of AWS profile and SSO status (with auth mode detection)
early_profile_check() {
  # If no profile specified, attempt to use default credential chain.
  if [[ -z $PROFILE ]]; then
    # Quick probe: can we call STS? (Used later anyway.)
    if aws_cmd sts get-caller-identity >/dev/null 2>&1; then
      info "Using default credential chain (no --profile specified)."
      return 0
    else
      err "No --profile specified and default credential chain failed."
      err "Provide credentials by one of:"
      err "  * aws configure (set a default or named profile)"
      err "  * export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (and optional AWS_SESSION_TOKEN)"
      err "  * use an SSO profile then run: aws sso login --profile <name>"
      err "  * use an EC2/ECS role (instance metadata)"
      exit 1
    fi
  fi

  info "Validating AWS profile: ${PROFILE}"

  # Check if profile exists in AWS config
  if ! aws configure list-profiles | grep -q "^${PROFILE}$" 2>/dev/null; then
    err "Profile '${PROFILE}' not found in AWS configuration"
    err "Available profiles: $(aws configure list-profiles | tr '\n' ' ')"
    return 1
  fi

  # Detect partial SSO configuration (one field present but others missing)
  local has_sso_start has_sso_region has_sso_account has_sso_role
  local sso_start_url sso_region sso_account_id sso_role_name
  sso_start_url=$(aws configure get sso_start_url --profile "$PROFILE" 2>/dev/null || true)
  sso_region=$(aws configure get sso_region --profile "$PROFILE" 2>/dev/null || true)
  sso_account_id=$(aws configure get sso_account_id --profile "$PROFILE" 2>/dev/null || true)
  sso_role_name=$(aws configure get sso_role_name --profile "$PROFILE" 2>/dev/null || true)
  [[ -n $sso_start_url ]] && has_sso_start=1 || has_sso_start=0
  [[ -n $sso_region ]] && has_sso_region=1 || has_sso_region=0
  [[ -n $sso_account_id ]] && has_sso_account=1 || has_sso_account=0
  [[ -n $sso_role_name ]] && has_sso_role=1 || has_sso_role=0

  local sso_field_count=$(( has_sso_start + has_sso_region + has_sso_account + has_sso_role ))
  if [[ $sso_field_count -gt 0 && $sso_field_count -lt 2 ]]; then
    err "Profile '${PROFILE}' appears to have partial SSO config (some SSO fields missing)."
    err "Fields present: start_url=${has_sso_start} region=${has_sso_region} account_id=${has_sso_account} role_name=${has_sso_role}"
    err "Please complete SSO configuration (need at least sso_start_url + sso_region)."
  fi

  # Check and handle SSO if needed
  check_sso_and_login || return 1

  # Final verification: get account info to confirm profile works
  local account_info
  if account_info=$(aws_cmd sts get-caller-identity 2>/dev/null); then
    local account_id user_arn auth_mode
    account_id=$(echo "$account_info" | jq -r '.Account')
    user_arn=$(echo "$account_info" | jq -r '.Arn')

    # Determine auth mode
    if [[ -n $sso_start_url ]]; then
      auth_mode="SSO"
    elif aws configure get aws_access_key_id --profile "$PROFILE" >/dev/null 2>&1; then
      auth_mode="StaticKeys"
    else
      auth_mode="Assumed/DefaultChain"
    fi

    info "✓ Profile '${PROFILE}' is active"
    info "  Account: ${account_id}"
    info "  Identity: ${user_arn}"
    info "  AuthMode: ${auth_mode}"
    if [[ $auth_mode == SSO ]]; then
      info "  IdentityCenter Start URL: ${sso_start_url} (region: ${sso_region:-unknown})"
      if [[ -n $sso_account_id || -n $sso_role_name ]]; then
        info "  SSO Target: account=${sso_account_id:-*} role=${sso_role_name:-*}"
      fi
    fi
    return 0
  else
    err "Profile '${PROFILE}' exists but cannot authenticate"
    err "Run 'aws sts get-caller-identity --profile ${PROFILE}' to debug"
    return 1
  fi
}
check_sso_and_login() {
  local profile_name="${PROFILE:-default}"
  
  # Skip SSO check if no profile specified (uses default credentials)
  [[ -z $PROFILE ]] && return 0
  
  # Check if profile exists and is SSO type
  local sso_start_url sso_region
  if ! sso_start_url=$(aws configure get sso_start_url --profile "$profile_name" 2>/dev/null); then
    debug "Profile $profile_name: no sso_start_url found"
  fi
  
  if ! sso_region=$(aws configure get sso_region --profile "$profile_name" 2>/dev/null); then
    debug "Profile $profile_name: no sso_region found"
  fi
  
  # Test if current session is valid first
  local sts_output sts_err
  sts_err=$(aws_cmd sts get-caller-identity 2>&1)
  local sts_exit_code=$?
  
  if [[ $sts_exit_code -eq 0 ]]; then
    debug "Session for profile $profile_name is valid"
    return 0
  fi
  
  # Check if error indicates SSO token issue
  if echo "$sts_err" | grep -iq "token has expired\|sso\|refresh failed\|unable to load sso"; then
    info "Detected SSO token issue for profile: $profile_name"
    info "Error: $sts_err"
    
    if [[ $YES -eq 1 || $FORCE -eq 1 ]]; then
      info "Auto-running: aws sso login --profile $profile_name"
      if ! aws sso login --profile "$profile_name"; then
        err "SSO login failed for profile: $profile_name"; return 1
      fi
    else
      echo "SSO session expired or invalid. You need to login." >&2
      if confirm "Run 'aws sso login --profile $profile_name' now?"; then
        if ! aws sso login --profile "$profile_name"; then
          err "SSO login failed for profile: $profile_name"; return 1
        fi
      else
        err "Cannot proceed without valid SSO session"; return 1
      fi
    fi
    
    # Verify login worked
    if ! aws_cmd sts get-caller-identity >/dev/null 2>&1; then
      err "SSO login completed but sts get-caller-identity still fails"; return 1
    fi
    
    info "SSO login successful for profile: $profile_name"
    return 0
  elif [[ -n $sso_start_url ]]; then
    # Has SSO config but different error
    info "Detected SSO profile: $profile_name (start_url: $sso_start_url) but unexpected error"
    info "Error: $sts_err"
    return 1
  else
    # Not SSO, probably regular credential issue
    debug "Profile $profile_name appears to be non-SSO, credential error: $sts_err"
    return 1
  fi
}

# List SSO accounts and roles available for current SSO cached session
list_sso_accounts_roles() {
  local profile_name="${PROFILE:-}"
  [[ -z $profile_name ]] && return 0
  local start_url sso_reg
  start_url=$(aws configure get sso_start_url --profile "$profile_name" 2>/dev/null || true)
  sso_reg=$(aws configure get sso_region --profile "$profile_name" 2>/dev/null || true)
  [[ -z $start_url || -z $sso_reg ]] && return 0  # Not an SSO profile

  # Attempt to enumerate SSO accounts (needs valid cached token)
  info "Enumerating SSO accounts and permission sets (profile: $profile_name) ..."
  local acct_json
  if ! acct_json=$(aws sso list-accounts --profile "$profile_name" 2>/dev/null); then
    debug "list-accounts failed (maybe token not yet established for enumeration)"
    return 0
  fi
  local accounts
  accounts=$(echo "$acct_json" | jq -r '.accountList[]? | @base64') || return 0
  [[ -z $accounts ]] && { info "  (No SSO accounts returned)"; return 0; }
  while IFS= read -r enc; do
    [[ -z $enc ]] && continue
    local id name email
    id=$(echo "$enc" | base64 --decode | jq -r '.accountId')
    name=$(echo "$enc" | base64 --decode | jq -r '.accountName')
    email=$(echo "$enc" | base64 --decode | jq -r '.emailAddress // ""')
    echo "  Account: $id  Name: $name  Email: $email" >&2
    # List roles (permission sets) for each account
    local role_json
    if role_json=$(aws sso list-account-roles --account-id "$id" --profile "$profile_name" 2>/dev/null); then
      echo "$role_json" | jq -r '.roleList[]? | "    Role: \(.roleName)"' >&2 || true
    fi
  done <<< "$accounts"
}

# Check user permissions across AWS regions and return accessible regions list
check_region_permissions() {
  info "Checking AWS region permissions..."
  
  # Common AWS regions list
  local all_regions=(
    "us-east-1" "us-east-2" "us-west-1" "us-west-2"
    "eu-west-1" "eu-west-2" "eu-west-3" "eu-central-1" "eu-north-1"
    "ap-northeast-1" "ap-northeast-2" "ap-southeast-1" "ap-southeast-2" "ap-south-1"
    "ca-central-1" "sa-east-1"
    "af-south-1" "me-south-1" "ap-east-1"
  )
  
  local accessible_regions=()
  local current_region_backup="$REGION"
  
  # Test each region by trying to call describe-regions
  for region in "${all_regions[@]}"; do
    REGION="$region"
    local test_result
    if test_result=$(aws_cmd ec2 describe-regions --region-names "$region" 2>/dev/null) && [[ -n "$test_result" ]]; then
      accessible_regions+=("$region")
      debug "✓ Region $region: accessible"
    else
      debug "✗ Region $region: no access or unavailable"
    fi
  done
  
  # Restore original region
  REGION="$current_region_backup"
  
  if [[ ${#accessible_regions[@]} -eq 0 ]]; then
    err "No accessible AWS regions found. Please check your permissions."
    return 1
  fi
  
  info "Found ${#accessible_regions[@]} accessible regions: ${accessible_regions[*]}"
  
  # Store accessible regions in global variable for use by other functions
  ACCESSIBLE_REGIONS=("${accessible_regions[@]}")
  return 0
}

# Interactive region selection from accessible regions
select_region_interactive() {
  local regions=("$@")
  
  if [[ ${#regions[@]} -eq 0 ]]; then
    err "No regions provided for selection"
    return 1
  fi
  
  echo "Available AWS regions (with access permissions):" >&2
  for i in "${!regions[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${regions[i]}" >&2
  done
  
  while true; do
    read -r -p "Select region [1-${#regions[@]}]: " choice
    
    # Validate input
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#regions[@]} ]]; then
      local selected_region="${regions[$((choice-1))]}"
      echo "$selected_region"
      return 0
    else
      echo "Invalid selection. Please enter a number between 1 and ${#regions[@]}." >&2
    fi
  done
}

# Validate that specified region is accessible
validate_region_access() {
  local target_region="$1"
  [[ -z "$target_region" ]] && { err "No region specified for validation"; return 1; }
  
  local current_region_backup="$REGION"
  REGION="$target_region"
  
  local test_result
  if test_result=$(aws_cmd ec2 describe-regions --region-names "$target_region" 2>/dev/null) && [[ -n "$test_result" ]]; then
    REGION="$current_region_backup"
    debug "✓ Region $target_region: access validated"
    return 0
  else
    REGION="$current_region_backup"
    err "Region '$target_region' is not accessible with current credentials"
    err "Please check your permissions or choose a different region"
    return 1
  fi
}

# Unified region configuration function
configure_regions_interactive() {
  echo "=== AWS Region Configuration ===" >&2
  echo "This will configure both the deployment region and scan regions." >&2
  echo "" >&2
  
  # Step 1: Check accessible regions
  echo "Checking available AWS regions with your current permissions..." >&2
  if check_region_permissions; then
    # Step 2: Select deployment region
    echo "" >&2
    echo "Step 1/2: Select Deployment Region" >&2
    echo "This region will be used for CloudFormation stack and Lambda deployment." >&2
    echo "" >&2
    echo "Choose deployment region:" >&2
    echo "  1) Select from accessible regions (${#ACCESSIBLE_REGIONS[@]} available)" >&2 
    echo "  2) Enter custom region manually" >&2
    read -r -p "Choose option [1/2] (default 1): " region_choice
    
    case "${region_choice:-1}" in
      1)
        REGION=$(select_region_interactive "${ACCESSIBLE_REGIONS[@]}")
        info "Selected deployment region: $REGION"
        ;;
      2)
        read -r -p "Enter AWS Region: " REGION
        while [[ -z $REGION ]]; do 
          read -r -p "AWS Region cannot be empty: " REGION
        done
        info "Validating region access: $REGION"
        if ! validate_region_access "$REGION"; then
          err "Region validation failed. Please try again."
          return 1
        fi
        ;;
      *)
        err "Invalid choice"
        return 1
        ;;
    esac
  else
    # Fallback if region checking fails
    echo "Warning: Region permission check failed. Manual region entry required." >&2
    read -r -p "Enter AWS Region for deployment: " REGION
    while [[ -z $REGION ]]; do 
      read -r -p "AWS Region cannot be empty: " REGION
    done
    info "Using manually entered region: $REGION"
  fi
  
  # Step 3: Configure scan regions and authorization strategy
  echo "" >&2
  echo "Step 2/2: Configure Scan Regions" >&2
  echo "Choose which AWS regions to scan for security configurations:" >&2
  
  if [[ ${#ACCESSIBLE_REGIONS[@]} -gt 0 ]]; then
    echo "  1) Scan all accessible regions (${#ACCESSIBLE_REGIONS[@]} available: ${ACCESSIBLE_REGIONS[*]})" >&2
    echo "  2) Scan only deployment region ($REGION)" >&2
    echo "  3) Scan only authorized regions (respects account region restrictions)" >&2
    echo "  4) Enter custom region list manually" >&2
    read -r -p "Choose scan strategy [1/2/3/4] (default 1): " scan_choice
    
    case "${scan_choice:-1}" in
      1)
        REGIONS_ARG="all"
        AUTHORIZED_REGIONS_ONLY="false"
        info "Will scan all accessible regions: ${ACCESSIBLE_REGIONS[*]}"
        ;;
      2)
        REGIONS_ARG="$REGION"
        AUTHORIZED_REGIONS_ONLY="false"
        info "Will scan only deployment region: $REGION"
        ;;
      3)
        REGIONS_ARG="all"
        AUTHORIZED_REGIONS_ONLY="true"
        info "Will scan all authorized regions (account restrictions apply)"
        ;;
      4)
        echo "Available regions: ${ACCESSIBLE_REGIONS[*]}" >&2
        read -r -p "Enter comma-separated region list: " custom_regions
        while [[ -z $custom_regions ]]; do
          read -r -p "Region list cannot be empty: " custom_regions
        done
        REGIONS_ARG="$custom_regions"
        AUTHORIZED_REGIONS_ONLY="false"
        info "Will scan custom regions: $custom_regions"
        ;;
      *)
        err "Invalid choice"
        return 1
        ;;
    esac
  else
    # Fallback when region permission check failed
    echo "  1) Scan all regions (default)" >&2
    echo "  2) Scan only deployment region ($REGION)" >&2
    echo "  3) Scan only authorized regions (respects account region restrictions)" >&2
    echo "  4) Enter custom region list manually" >&2
    read -r -p "Choose scan strategy [1/2/3/4] (default 1): " scan_choice
    
    case "${scan_choice:-1}" in
      1)
        REGIONS_ARG="all"
        AUTHORIZED_REGIONS_ONLY="false"
        info "Will scan all regions"
        ;;
      2)
        REGIONS_ARG="$REGION"
        AUTHORIZED_REGIONS_ONLY="false"
        info "Will scan only deployment region: $REGION"
        ;;
      3)
        REGIONS_ARG="all"
        AUTHORIZED_REGIONS_ONLY="true"
        info "Will scan all authorized regions (account restrictions apply)"
        ;;
      4)
        read -r -p "Enter comma-separated region list: " custom_regions
        while [[ -z $custom_regions ]]; do
          read -r -p "Region list cannot be empty: " custom_regions
        done
        REGIONS_ARG="$custom_regions"
        AUTHORIZED_REGIONS_ONLY="false"
        info "Will scan custom regions: $custom_regions"
        ;;
      *)
        err "Invalid choice"
        return 1
        ;;
    esac
  fi
  
  echo "" >&2
  echo "✓ Region configuration completed:" >&2
  echo "  Deployment region: $REGION" >&2
  echo "  Scan regions: $REGIONS_ARG" >&2
  echo "  Authorized-regions-only: $AUTHORIZED_REGIONS_ONLY" >&2
  echo "" >&2
  
  return 0
}

find_binaries() {
  local default_dir
  default_dir="${PWD}/dist"
  local dir="${BINARY_DIR:-$default_dir}"; [[ -d $dir ]] || { err "Binary dir not found: $dir"; exit 1; }
  local amd_candidates=( awsconfcheck-amd64 awsconfcheck-x86_64 awsconfcheck-linux-amd64 )
  local arm_candidates=( awsconfcheck-arm64 awsconfcheck-aarch64 awsconfcheck-linux-arm64 )
  local found_amd="" found_arm=""
  for n in "${amd_candidates[@]}"; do [[ -x "$dir/$n" ]] && { found_amd="$dir/$n"; break; }; done
  for n in "${arm_candidates[@]}"; do [[ -x "$dir/$n" ]] && { found_arm="$dir/$n"; break; }; done
  if [[ -z $found_amd && -z $found_arm ]]; then
    err "No prebuilt awsconfcheck binaries found in $dir"; exit 1
  fi
  if [[ -n $found_amd ]]; then PREBUILT_AMD64="$found_amd"; else ENABLE_AMD64=false; fi
  if [[ -n $found_arm ]]; then PREBUILT_ARM64="$found_arm"; else ENABLE_ARM64=false; fi
  info "Detected binaries: amd64=${PREBUILT_AMD64:-none} arm64=${PREBUILT_ARM64:-none}"
  if [[ $ARCH_MODE == both ]]; then ARCH_MODE="auto"; fi
  if [[ $ARCH_MODE == amd64 && $ENABLE_AMD64 == false ]]; then err "Requested amd64 invoke but no amd64 binary"; exit 1; fi
  if [[ $ARCH_MODE == arm64 && $ENABLE_ARM64 == false ]]; then err "Requested arm64 invoke but no arm64 binary"; exit 1; fi
}

precheck_permissions() {
  info "Starting permission precheck..."
  local MUST_ACTIONS_DEPLOY=(
    sts:GetCallerIdentity
    cloudformation:CreateStack cloudformation:UpdateStack cloudformation:DeleteStack cloudformation:DescribeStacks
    lambda:CreateFunction lambda:UpdateFunctionCode lambda:UpdateFunctionConfiguration lambda:DeleteFunction lambda:GetFunction
    iam:PassRole iam:CreateRole iam:DeleteRole iam:AttachRolePolicy iam:DetachRolePolicy iam:PutRolePolicy iam:DeleteRolePolicy iam:GetRole
    s3:CreateBucket s3:DeleteBucket s3:PutBucketTagging s3:GetBucketTagging s3:ListBucket s3:GetBucketLocation s3:PutObject s3:DeleteObject
  )
  local READ_PROBES=(
    "cloudformation list-stacks"
    "lambda list-functions"
    "ec2 describe-regions"
    "iam get-account-summary"
    "s3api list-buckets"
  )
  if ! aws_cmd sts get-caller-identity >/dev/null 2>&1; then
    err "Precheck: sts:GetCallerIdentity failed (credentials invalid)."; return 2
  fi
  local ACCOUNT
  ACCOUNT=$(aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)
  local simulate_ok=0
  if aws_cmd iam simulate-principal-policy --policy-source-arn arn:aws:iam::${ACCOUNT}:root --action-names sts:GetCallerIdentity >/dev/null 2>&1; then
    simulate_ok=1
  fi
  local SIM_FILE=""
  if [[ $simulate_ok -eq 1 ]]; then
    info "Using iam:SimulatePrincipalPolicy for deployment action evaluation"
    SIM_FILE=$(mktemp)
    local batch=() count=0
    submit_batch() {
      [[ ${#batch[@]} -eq 0 ]] && return 0
      local out
      if out=$(aws_cmd iam simulate-principal-policy --policy-source-arn arn:aws:iam::${ACCOUNT}:root --action-names "${batch[@]}" 2>/dev/null); then
        echo "$out" | jq -r '.EvaluationResults[] | .EvalActionName+" " + .EvalDecision' >> "$SIM_FILE" || true
      fi
      batch=(); count=0
    }
    for a in "${MUST_ACTIONS_DEPLOY[@]}"; do
      batch+=("$a"); count=$((count+1))
      if [[ $count -ge 90 ]]; then submit_batch; fi
    done
    submit_batch
  else
    info "iam:SimulatePrincipalPolicy not available; marking create/update actions as UNKNOWN"
  fi
  for call in "${READ_PROBES[@]}"; do
    local svc=${call%% *}; local rest=${call#* }
    aws_cmd $svc $rest >/dev/null 2>&1 || true
  done
  local fatal=0
  echo "Required deployment actions (simulated):" >&2
  for a in "${MUST_ACTIONS_DEPLOY[@]}"; do
    local dec="UNKNOWN"
    if [[ -n $SIM_FILE && -s $SIM_FILE ]]; then
      local line
      line=$(grep -F "${a} " "$SIM_FILE" | head -n1 || true)
      [[ -n $line ]] && dec=${line#${a} }
    fi
    local low=$(printf '%s' "$dec" | tr 'A-Z' 'a-z')
    local status
    if [[ $low == *allow* ]]; then status=PASS
    elif [[ $low == *deny* ]]; then status=DENIED; fatal=1
    else status=UNKNOWN; fi
    printf "  %-42s %s\n" "$a" "$status" >&2
  done
  [[ -n $SIM_FILE ]] && rm -f "$SIM_FILE" || true
  if [[ $fatal -eq 1 ]]; then
    err "Precheck FAILED (critical actions denied)"; return 3
  fi
  info "Precheck completed (no critical denies)."; return 0
}

precheck_cloudformation() {
  info "Starting CloudFormation live precheck (create/update/delete) ..."
  local test_stack="awsconfcheck-precheck-${STACK_NAME}-$(now_ts)"
  local tmp_template
  tmp_template=$(mktemp)
  cat > "$tmp_template" <<'CFN'
AWSTemplateFormatVersion: '2010-09-09'
Description: awsconfcheck precheck minimal stack
Resources:
  PrecheckLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub /awsconfcheck/precheck/${AWS::StackName}
      RetentionInDays: 1
CFN
  if ! aws_cmd cloudformation create-stack --stack-name "$test_stack" --template-body file://"$tmp_template" >/dev/null 2>&1; then
    err "CFN precheck: create-stack failed"; rm -f "$tmp_template"; return 4
  fi
  aws_cmd cloudformation wait stack-create-complete --stack-name "$test_stack" >/dev/null 2>&1 || { err "CFN precheck: wait create failed"; }
  info "CFN precheck: create success ($test_stack)"
  if ! aws_cmd cloudformation update-stack --stack-name "$test_stack" --template-body file://"$tmp_template" >/dev/null 2>&1; then
    local upd_log
    upd_log=$(aws_cmd cloudformation update-stack --stack-name "$test_stack" --template-body file://"$tmp_template" 2>&1 || true)
    if echo "$upd_log" | grep -q 'No updates are to be performed'; then
      info "CFN precheck: update no-op (acceptable)"
    else
      err "CFN precheck: update-stack failed"; rm -f "$tmp_template"; aws_cmd cloudformation delete-stack --stack-name "$test_stack" >/dev/null 2>&1 || true; return 5
    fi
  else
    aws_cmd cloudformation wait stack-update-complete --stack-name "$test_stack" >/dev/null 2>&1 || info "CFN precheck: wait update issue (continuing)"
    info "CFN precheck: update success"
  fi
  if ! aws_cmd cloudformation delete-stack --stack-name "$test_stack" >/dev/null 2>&1; then
    err "CFN precheck: delete-stack failed"; rm -f "$tmp_template"; return 6
  fi
  aws_cmd cloudformation wait stack-delete-complete --stack-name "$test_stack" >/dev/null 2>&1 || { err "CFN precheck: wait delete failed"; return 7; }
  info "CFN precheck: delete success"
  rm -f "$tmp_template" || true
  info "CloudFormation live precheck completed successfully"
}

package_binaries() {
  mkdir -p "$DIST_DIR/pkg-amd64" "$DIST_DIR/pkg-arm64"
  BOOTSTRAP_CONTENT=$(cat <<'BOOT_EOF'
#!/bin/sh
set -e
BIN="/var/task/awsconfcheck"
RUNTIME_API="${AWS_LAMBDA_RUNTIME_API:-}"
SINGLE_RUN_MODE="${SINGLE_RUN:-1}"
if [ -z "$RUNTIME_API" ]; then
  echo "[bootstrap] NOTICE: local build context (no AWS_LAMBDA_RUNTIME_API); skipping runtime loop." >&2
  exit 0
fi
run_once() {
  RESP_HEADERS=$(mktemp)
  if ! curl -sS -D "$RESP_HEADERS" "http://$RUNTIME_API/2018-06-01/runtime/invocation/next" -o /tmp/event; then
    echo "[bootstrap] failed to fetch event" >&2
    return 1
  fi
  REQ_ID=$(grep -Fi Lambda-Runtime-Aws-Request-Id "$RESP_HEADERS" | awk '{print $2}' | tr -d '\r')
  START_TS=$(date +%s)
  /bin/sh -c "$BIN" > /tmp/out.all 2>&1 || true
  RESP_LINE=$(grep -m1 '{"status"' /tmp/out.all || true)
  [ -z "$RESP_LINE" ] && RESP_LINE='{"status":"error","error":"no_status_json"}'
  curl -sS -X POST -H "Content-Type: application/json" "http://$RUNTIME_API/2018-06-01/runtime/invocation/$REQ_ID/response" -d "$RESP_LINE" >/dev/null || true
  END_TS=$(date +%s)
  echo "[bootstrap] handled request $REQ_ID in $((END_TS-START_TS))s" >&2
  rm -f "$RESP_HEADERS" /tmp/event >/dev/null 2>&1 || true
}
if [ "$SINGLE_RUN_MODE" = "1" ] || [ "$SINGLE_RUN_MODE" = "true" ]; then
  run_once || true
  echo "[bootstrap] single-run complete" >&2
  exit 0
fi
while true; do run_once || true; done
BOOT_EOF
)
  if [[ $ENABLE_AMD64 == true ]]; then
    printf "%s" "$BOOTSTRAP_CONTENT" > "$DIST_DIR/pkg-amd64/bootstrap"; chmod +x "$DIST_DIR/pkg-amd64/bootstrap"
    cp "$PREBUILT_AMD64" "$DIST_DIR/pkg-amd64/awsconfcheck"
    (cd "$DIST_DIR/pkg-amd64" && zip -qr "$DIST_DIR/lambda-amd64.zip" .)
    CODE_KEY_AMD64="lambda/${STACK_NAME}/lambda-amd64.zip"
  fi
  if [[ $ENABLE_ARM64 == true ]]; then
    printf "%s" "$BOOTSTRAP_CONTENT" > "$DIST_DIR/pkg-arm64/bootstrap"; chmod +x "$DIST_DIR/pkg-arm64/bootstrap"
    cp "$PREBUILT_ARM64" "$DIST_DIR/pkg-arm64/awsconfcheck"
    (cd "$DIST_DIR/pkg-arm64" && zip -qr "$DIST_DIR/lambda-arm64.zip" .)
    CODE_KEY_ARM64="lambda/${STACK_NAME}/lambda-arm64.zip"
  fi
  info "Packaged zips: $(ls -1 $DIST_DIR | grep lambda- || true)"
}

aws_preflight() {
  require jq; require zip; require aws; require curl
  [[ -n $REGION ]] || { err "--region required"; exit 1; }
  [[ -z $STACK_NAME ]] && STACK_NAME="awsconfcheck-$(now_ts)"
  
  local acct
  if ! acct=$(aws_cmd sts get-caller-identity --query Account --output text 2>/dev/null); then
    err "STS get-caller-identity failed for profile: ${PROFILE:-default}"; exit 1
  fi
  ACCOUNT_ID="$acct"
  if [[ -z $BUCKET_NAME ]]; then
    if [[ $RANDOM_BUCKET -eq 1 ]]; then
      BUCKET_NAME="awsconfcheck-${ACCOUNT_ID}-${REGION}-$(rand_suffix)"
    else
      local norm_stack
      norm_stack=$(echo "$STACK_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')
      norm_stack=${norm_stack%-}
      BUCKET_NAME="awsconfcheck-${ACCOUNT_ID}-${REGION}-${norm_stack}"
      [[ ${#BUCKET_NAME} -gt 63 ]] && BUCKET_NAME=${BUCKET_NAME:0:63}
    fi
  fi
  info "Account: $ACCOUNT_ID"
  info "Stack:   $STACK_NAME"
  info "Bucket:  $BUCKET_NAME"
}

ensure_bucket_and_upload() {
  if ! aws_cmd s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
    info "Creating bucket $BUCKET_NAME ..."
    if [[ $REGION == us-east-1 ]]; then
      aws_cmd s3api create-bucket --bucket "$BUCKET_NAME" >/dev/null || true
    else
      aws_cmd s3api create-bucket --bucket "$BUCKET_NAME" --create-bucket-configuration LocationConstraint="$REGION" >/dev/null || true
    fi
    aws_cmd s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging "TagSet=[{Key=ManagedBy,Value=awsconfcheck},{Key=Stack,Value=${STACK_NAME}}]" >/dev/null || true
    aws_cmd s3api put-object --bucket "$BUCKET_NAME" --key ".awsconfcheck-marker" --content-length 0 >/dev/null || true
  else
    local existing_tag_json
    existing_tag_json=$(aws_cmd s3api get-bucket-tagging --bucket "$BUCKET_NAME" 2>/dev/null || true)
    if ! echo "$existing_tag_json" | jq -e '.TagSet[]? | select(.Key=="ManagedBy" and .Value=="awsconfcheck")' >/dev/null 2>&1; then
      aws_cmd s3api put-bucket-tagging --bucket "$BUCKET_NAME" --tagging "TagSet=[{Key=ManagedBy,Value=awsconfcheck},{Key=Stack,Value=${STACK_NAME}}]" >/dev/null || true
    fi
    if ! aws_cmd s3api head-object --bucket "$BUCKET_NAME" --key ".awsconfcheck-marker" >/dev/null 2>&1; then
      aws_cmd s3api put-object --bucket "$BUCKET_NAME" --key ".awsconfcheck-marker" --content-length 0 >/dev/null || true
    fi
  fi
  info "Uploading packaged zips ..."
  [[ $ENABLE_AMD64 == true ]] && aws_cmd s3 cp "$DIST_DIR/lambda-amd64.zip" "s3://$BUCKET_NAME/$CODE_KEY_AMD64" >/dev/null
  [[ $ENABLE_ARM64 == true ]] && aws_cmd s3 cp "$DIST_DIR/lambda-arm64.zip" "s3://$BUCKET_NAME/$CODE_KEY_ARM64" >/dev/null
}

# Cleanup mode: list and optionally delete stacks, functions, and buckets tagged ManagedBy=awsconfcheck
cleanup_resources() {
  require jq
  info "Cleanup Mode: scanning for resources created by awsconfcheck ..."
  # Stacks (regional)
  local stacks
  stacks=$(aws_cmd cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE 2>/dev/null \
    | jq -r '.StackSummaries[] | select(.StackName | startswith("awsconfcheck-")) | .StackName' || true)
  # Functions (regional)
  local functions
  functions=$(aws_cmd lambda list-functions --max-items 1000 2>/dev/null | jq -r '.Functions[] | select(.FunctionName | startswith("awsconfcheck-")) | .FunctionName' || true)
  # Buckets (global list, filter by prefix and tag)
  local buckets raw_buckets tagged_buckets
  raw_buckets=$(aws_cmd s3api list-buckets 2>/dev/null | jq -r '.Buckets[]?.Name' | grep '^awsconfcheck-' || true)
  if [[ -n $raw_buckets ]]; then
    while IFS= read -r b; do
      [[ -z $b ]] && continue
      local tag_json
      tag_json=$(aws_cmd s3api get-bucket-tagging --bucket "$b" 2>/dev/null || true)
      if echo "$tag_json" | jq -e '.TagSet[]? | select(.Key=="ManagedBy" and .Value=="awsconfcheck")' >/dev/null 2>&1; then
        tagged_buckets+="$b"$'\n'
      fi
    done <<< "$raw_buckets"
  fi
  buckets=$(printf '%s' "${tagged_buckets:-}" | sed '/^$/d' || true)

  echo "---- Stacks ----" >&2
  if [[ -n $stacks ]]; then echo "$stacks" >&2; else echo "(none)" >&2; fi
  echo "---- Functions ----" >&2
  if [[ -n $functions ]]; then echo "$functions" >&2; else echo "(none)" >&2; fi
  echo "---- Buckets (tagged ManagedBy=awsconfcheck) ----" >&2
  if [[ -n $buckets ]]; then echo "$buckets" >&2; else echo "(none)" >&2; fi

  if [[ -z $stacks && -z $functions && -z $buckets ]]; then
    info "No awsconfcheck stacks/functions/tagged buckets found. Nothing to clean."
    info "(If you expected resources: ensure you are in the correct region/account and credentials are valid.)"
    return 0
  fi

  if [[ $YES -eq 1 || $FORCE -eq 1 ]]; then
    info "--yes/--force provided: skipping interactive cleanup."
    return 0
  fi

  echo "Select category to delete: (1) stack  (2) function  (3) bucket  (q to quit)" >&2
  while true; do
    read -r -p "Enter choice [1/2/3/q]: " c || break
    case "$c" in
      1)
        [[ -z $stacks ]] && echo "No deletable stacks" >&2 && continue
        read -r -p "Enter stack name to delete (* for all / Enter to cancel): " target
        [[ -z $target ]] && continue
        if [[ $target == '*' ]]; then
          for s in $stacks; do info "Deleting stack $s"; aws_cmd cloudformation delete-stack --stack-name "$s" || true; done
        else
          info "Deleting stack $target"; aws_cmd cloudformation delete-stack --stack-name "$target" || true
        fi
        ;;
      2)
        [[ -z $functions ]] && echo "No deletable functions" >&2 && continue
        read -r -p "Enter function name to delete (* for all / Enter to cancel): " target
        [[ -z $target ]] && continue
        if [[ $target == '*' ]]; then
          for f in $functions; do info "Deleting function $f"; aws_cmd lambda delete-function --function-name "$f" || true; done
        else
          info "Deleting function $target"; aws_cmd lambda delete-function --function-name "$target" || true
        fi
        ;;
      3)
        [[ -z $buckets ]] && echo "No deletable buckets (tagged ManagedBy=awsconfcheck)" >&2 && continue
        read -r -p "Enter bucket name to delete (* for all / Enter to cancel): " target
        [[ -z $target ]] && continue
        if [[ $target == '*' ]]; then
          for b in $buckets; do info "Deleting bucket $b (objects)"; aws_cmd s3 rm "s3://$b" --recursive || true; aws_cmd s3api delete-bucket --bucket "$b" || true; done
        else
          info "Deleting bucket $target (objects)"; aws_cmd s3 rm "s3://$target" --recursive || true; aws_cmd s3api delete-bucket --bucket "$target" || true
        fi
        ;;
      q|Q)
        break;;
      *) echo "Invalid option" >&2;;
    esac
  done
  info "Cleanup mode finished"
}

deploy_stack() {
  local enableAmd="false" enableArm="false"
  [[ $ENABLE_AMD64 == true ]] && enableAmd="true"
  [[ $ENABLE_ARM64 == true ]] && enableArm="true"
  local params=(
    --stack-name "$STACK_NAME"
    --template-file "$TEMPLATE_FILE"
    --capabilities CAPABILITY_NAMED_IAM
    --parameter-overrides \
      StackNameParam="$STACK_NAME" \
      BucketName="$BUCKET_NAME" \
      CodeKeyAmd64="$CODE_KEY_AMD64" \
      CodeKeyArm64="$CODE_KEY_ARM64" \
      ReportPrefix="$REPORT_PREFIX" \
      RoleArn="$ROLE_ARN" \
      ExternalId="$EXTERNAL_ID" \
      SessionName="$SESSION_NAME" \
      Regions="$REGIONS_ARG" \
      Concurrency="$CONCURRENCY" \
      AuthorizedRegionsOnly="$AUTHORIZED_REGIONS_ONLY" \
      EnableAmd64="$enableAmd" EnableArm64="$enableArm" SingleRun="$( (( SINGLE_RUN==1 )) && echo true || echo false )"
  )
  aws_cmd cloudformation deploy "${params[@]}"
}

invoke_lambda() {
  [[ $INVOKE -eq 1 ]] || return 0
  local chosen="$ARCH_MODE"
  if [[ $chosen == auto ]]; then
    if [[ $ENABLE_ARM64 == true ]]; then chosen=arm64; elif [[ $ENABLE_AMD64 == true ]]; then chosen=amd64; fi
  fi
  local fn="awsconfcheck-${chosen}-${STACK_NAME}"
  info "Invoking $fn ..."
  local out_file="$DIST_DIR/invoke-${chosen}.json"
  aws_cmd lambda invoke --function-name "$fn" "$out_file" >/dev/null || true
  if [[ -s $out_file ]]; then cat "$out_file" | jq '.' || cat "$out_file"; fi
  local status=$(jq -r '.status // empty' "$out_file" 2>/dev/null || true)
  local report_key=$(jq -r '.report_key // empty' "$out_file" 2>/dev/null || true)
  if [[ $status == ok && -n $report_key ]]; then
    echo "Report S3: s3://$BUCKET_NAME/$report_key" >&2
    echo "HTTPS (private): https://$BUCKET_NAME.s3.$REGION.amazonaws.com/$report_key" >&2
  else
    err "Invocation did not return ok status (status=$status)"
  fi
}

tail_logs() {
  [[ $LOG_TAIL -eq 1 ]] || return 0
  local chosen="$ARCH_MODE"
  if [[ $chosen == auto ]]; then
    if [[ $ENABLE_ARM64 == true ]]; then chosen=arm64; elif [[ $ENABLE_AMD64 == true ]]; then chosen=amd64; fi
  fi
  local fn="awsconfcheck-${chosen}-${STACK_NAME}"
  info "Tailing logs for $fn (30s) ..."
  aws_cmd logs tail "/aws/lambda/${fn}" --since 5m --follow --format short &
  local pid=$!
  sleep 30
  kill $pid >/dev/null 2>&1 || true
}

clean_dist() { rm -rf "$DIST_DIR" 2>/dev/null || true; }

main() {
  if [[ $# -eq 0 ]]; then INTERACTIVE=1; info "Interactive mode (prebuilt)"; fi
  parse_args "$@"

  # Re-evaluate ROLE_FLAGS_USED after argument parsing
  ROLE_FLAGS_USED=0
  if [[ -n $ROLE_ARN || -n $EXTERNAL_ID || $SESSION_NAME != "awsconfcheck-session" ]]; then
    ROLE_FLAGS_USED=1
    info "(soft-deprecated) --role-arn/--external-id/--session-name are hidden from help and will be removed in a future version."
    info "Current mode is single-account; recommend migrating to execution role permissions instead of AssumeRole."
  fi

  # Immediate feedback for cleanup mode so user sees a prompt even if later validation fails early
  if [[ $CLEANUP_MODE -eq 1 ]]; then
    echo "[INFO] Entering cleanup mode: discovering awsconfcheck stacks / lambdas / buckets ..." >&2
    # Provide guidance if commonly omitted parameters are missing
    if [[ -z $REGION || -z $PROFILE ]]; then
      echo "[HINT] Recommend specifying both --profile and --region to ensure correct resource listing." >&2
      echo "[HINT] Example: ./deploy_prebuilt.sh --profile xxx --region us-east-1 --cleanup" >&2
      if [[ -z $REGION ]]; then
        echo "[HINT] --region not provided. If no default region is configured you may see: 'You must specify a region'." >&2
      fi
      if [[ -z $PROFILE ]]; then
        echo "[HINT] --profile not provided. Will use default credential chain (env / instance role). For a specific account use: --profile sectest" >&2
      fi
    fi
  fi
  
  # Early profile validation for non-interactive mode
  if [[ $INTERACTIVE -eq 0 ]]; then
    early_profile_check
    
    # Validate region access in non-interactive mode
    if [[ -n $REGION ]]; then
      info "Validating region access: $REGION"
      if ! validate_region_access "$REGION"; then
        err "Region '$REGION' is not accessible. Use --region to specify a valid region."
        exit 1
      fi
    fi
  fi
  
  if [[ $INTERACTIVE -eq 1 ]]; then
    # Profile input with re-prompt loop (blank allowed -> default chain)
    while true; do
      read -r -p "Profile (blank=default): " PROFILE || true
      if [[ -z $PROFILE ]]; then
        # Attempt default chain probe here (already in early_profile_check logic but we want early feedback)
        if aws sts get-caller-identity >/dev/null 2>&1; then
          info "Using default credential chain (no profile)."
          break
        else
          err "No credentials found via default chain. Provide a profile or export credentials."
          continue
        fi
      else
        if early_profile_check; then
          # If SSO profile, list accounts/roles
          if aws configure get sso_start_url --profile "$PROFILE" >/dev/null 2>&1; then
            list_sso_accounts_roles || true
          fi
          break
        else
          err "Profile validation failed. Re-enter." >&2
        fi
      fi
    done
    
    # Unified region configuration
    if ! configure_regions_interactive; then
      err "Region configuration failed. Please try again."
      exit 1
    fi
    
    read -r -p "Stack name (blank=auto): " STACK_NAME || true
    read -r -p "Custom bucket name (blank=auto): " BUCKET_NAME || true
    [[ -z $BUCKET_NAME ]] && { read -r -p "Random bucket suffix? (y/N): " a; [[ $a =~ ^[Yy]$ ]] && RANDOM_BUCKET=1; }
    read -r -p "Architecture to invoke [amd64|arm64|auto] (auto): " ARCH_MODE || true
    [[ -z $ARCH_MODE ]] && ARCH_MODE=auto
    read -r -p "Binary directory (blank=./dist): " BINARY_DIR || true
  # Soft-deprecated: interactive prompts removed for role assume parameters.
  # Users can still pass --role-arn / --external-id / --session-name via CLI (hidden in help).
    read -r -p "Concurrency (10): " CIN || true; [[ -n $CIN ]] && CONCURRENCY="$CIN"
    read -r -p "Keep loop running? (y/N): " a || true; [[ $a =~ ^[Yy]$ ]] && SINGLE_RUN=0
    read -r -p "Invoke after deploy? (Y/n): " a || true; [[ $a =~ ^[Nn]$ ]] && INVOKE=0
    read -r -p "Tail logs 30s? (y/N): " a || true; [[ $a =~ ^[Yy]$ ]] && LOG_TAIL=1
    
    echo "Config summary:" >&2
    echo " Deployment region: $REGION" >&2
    echo " Scan regions: $REGIONS_ARG" >&2
    echo " Authorized-regions-only: $AUTHORIZED_REGIONS_ONLY" >&2
    echo " Stack: ${STACK_NAME:-<auto>}" >&2
    echo " Bucket: ${BUCKET_NAME:-<auto>} random=$RANDOM_BUCKET" >&2
    echo " Arch mode: $ARCH_MODE" >&2
    echo " Binary dir: ${BINARY_DIR:-$SCRIPT_DIR}" >&2
  [[ -n $ROLE_ARN ]] && echo " Role ARN (soft-deprecated flag in use): ${ROLE_ARN}" >&2
    echo " Concurrency: $CONCURRENCY" >&2
    echo " Single run: $SINGLE_RUN" >&2
    echo " Invoke: $INVOKE" >&2
    echo " Tail logs: $LOG_TAIL" >&2
    confirm "Proceed?" || { info "Aborted"; exit 0; }
  fi
  [[ $DEBUG -eq 1 ]] && set -x

  if [[ $PRECHECK -eq 1 || $PRECHECK_CFN -eq 1 ]]; then
    # Need REGION early for aws_cmd; basic STS identity checked in aws_preflight or here
    [[ -n $REGION ]] || { err "--region required for precheck"; exit 1; }
    if [[ -z $STACK_NAME ]]; then STACK_NAME="awsconfcheck-$(now_ts)"; fi
    
    # Check SSO for prechecks too
    check_sso_and_login || exit 1
    
    if [[ $PRECHECK -eq 1 ]]; then
      precheck_permissions || exit $?
      exit 0
    fi
    if [[ $PRECHECK_CFN -eq 1 ]]; then
      precheck_cloudformation || exit $?
      exit 0
    fi
  fi

  if [[ $CLEANUP_MODE -eq 1 ]]; then
    echo "============================================" >&2
    echo " AWSCONFCHECK CLEANUP MODE" >&2
    echo " This will list and optionally delete stacks, lambdas and tagged buckets" >&2
    echo " Use --yes / --force to skip prompts" >&2
    echo "============================================" >&2
    # Profile / credential validation (reuse earlier logic)
    if [[ -n $PROFILE ]]; then
      early_profile_check || { err "Credential/profile check failed for cleanup"; exit 1; }
    else
      # Probe default chain to provide friendly hint if empty
      if ! aws sts get-caller-identity >/dev/null 2>&1; then
        err "No credentials available (default chain failed). Provide --profile or export keys before --cleanup."
        exit 1
      fi
    fi
    # SSO re-check (in case profile is SSO and token expired)
    check_sso_and_login || exit 1
    cleanup_resources || true
    exit 0
  fi


  find_binaries
  aws_preflight
  package_binaries
  ensure_bucket_and_upload
  deploy_stack
  invoke_lambda
  tail_logs || true
  clean_dist
  info "Done (prebuilt)"
}

main "$@"
