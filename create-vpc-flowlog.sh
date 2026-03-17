#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly FLOWLOG_NAME="darktrace"
readonly TRAFFIC_TYPE="ALL"
readonly DEFAULT_CACHE_TTL_SECONDS="30"
readonly DEFAULT_REGION_MAP_FILE="$SCRIPT_DIR/region-s3-buckets.conf"

VPC_CACHE_TTL_SECONDS="${VPC_CACHE_TTL_SECONDS:-${CACHE_TTL_SECONDS:-$DEFAULT_CACHE_TTL_SECONDS}}"
FLOWLOG_CACHE_TTL_SECONDS="${FLOWLOG_CACHE_TTL_SECONDS:-0}"
REGION_MAP_FILE="${REGION_MAP_FILE:-$DEFAULT_REGION_MAP_FILE}"
QUIET=false
VERBOSE=false

usage() {
  cat >&2 <<EOF
Usage: $SCRIPT_NAME --region <region> --profile <aws-profile> [OPTIONS]

Creates a VPC Flow Log to the region-mapped S3 bucket with:
- Traffic type: ALL
- Partition logs by time: Every 1 hour
- Tag Name: darktrace

The script will:
- Discover all VPCs in the selected region
- Show if each VPC already has a Flow Log with Name=darktrace
- Let you choose which VPC to use

Required:
  -r, --region <region>
  -p, --profile <aws-profile>

Options:
  -q, --quiet      Reduce progress output
  -v, --verbose    Show cache/debug details
  -h, --help       Show this help

Environment variables:
  VPC_CACHE_TTL_SECONDS      VPC cache TTL in seconds (default: 30)
  FLOWLOG_CACHE_TTL_SECONDS  Flow Log cache TTL in seconds (default: 0)
  REGION_MAP_FILE            Path to region-to-S3 config file

Supported regions are loaded from:
  $DEFAULT_REGION_MAP_FILE
EOF
}

die() {
  echo "$SCRIPT_NAME: error: $*" >&2
  exit 1
}

usage_error() {
  echo "$SCRIPT_NAME: error: $*" >&2
  usage
  exit 2
}

log() {
  $QUIET || echo "$*"
}

debug() {
  if $VERBOSE; then
    echo "$*" >&2
  fi
}

run_aws() {
  aws "${aws_args[@]}" "$@"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sanitize_cache_key() {
  local s="$1"
  s="${s//\//_}"
  s="${s// /_}"
  printf "%s" "$s"
}

cache_is_fresh() {
  local file="$1"
  local ttl="$2"
  [[ -f "$file" ]] || return 1

  local now ts age
  now=$(date +%s)
  ts=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  age=$((now - ts))
  (( age >= 0 && age <= ttl ))
}

append_space_list() {
  local current="$1"
  local value="$2"
  if [[ -z "$current" ]]; then
    printf "%s" "$value"
  else
    printf "%s %s" "$current" "$value"
  fi
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i
  for ((i=0; i<count; i++)); do
    out+="$char"
  done
  printf "%s" "$out"
}

clip_text() {
  local text="$1"
  local max_len="$2"
  if (( ${#text} > max_len )); then
    printf "%s..." "${text:0:max_len-3}"
  else
    printf "%s" "$text"
  fi
}

trim() {
  local text="$1"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf "%s" "$text"
}

get_log_destination_from_config() {
  local target_region="$1"
  local config_file="$2"
  local line key value

  [[ -f "$config_file" ]] || die "region map file not found: $config_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue

    [[ "$line" == *"="* ]] || continue
    key="$(trim "${line%%=*}")"
    value="$(trim "${line#*=}")"

    if [[ "$key" == "$target_region" ]]; then
      [[ -n "$value" ]] || die "empty S3 destination for region '$target_region' in $config_file"
      printf "%s" "$value"
      return 0
    fi
  done < "$config_file"

  return 1
}

aws_args=()
profile=""
region=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--region)
      [[ $# -ge 2 ]] || usage_error "missing value for $1"
      region="$2"
      shift 2
      ;;
    -p|--profile)
      [[ $# -ge 2 ]] || usage_error "missing value for $1"
      profile="$2"
      shift 2
      ;;
    -q|--quiet)
      QUIET=true
      shift
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage_error "unknown option: $1 (see --help)"
      ;;
    *)
      usage_error "unexpected argument: $1 (see --help)"
      ;;
  esac
done

[[ -n "$region" ]] || usage_error "--region is required"
[[ -n "$profile" ]] || usage_error "--profile is required"
[[ "$VPC_CACHE_TTL_SECONDS" =~ ^[0-9]+$ ]] || usage_error "VPC_CACHE_TTL_SECONDS must be a non-negative integer"
[[ "$FLOWLOG_CACHE_TTL_SECONDS" =~ ^[0-9]+$ ]] || usage_error "FLOWLOG_CACHE_TTL_SECONDS must be a non-negative integer"

require_cmd aws
require_cmd stat

aws_args+=(--region "$region")
aws_args+=(--profile "$profile")

set +e
log_destination="$(get_log_destination_from_config "$region" "$REGION_MAP_FILE")"
config_rc=$?
set -e

if [[ $config_rc -ne 0 ]]; then
  usage_error "unsupported region: $region (not found in $REGION_MAP_FILE)"
fi

log "Using region: $region"
log "Using profile: $profile"
debug "Region map file: $REGION_MAP_FILE"
debug "VPC cache TTL seconds: $VPC_CACHE_TTL_SECONDS"
debug "Flow Log cache TTL seconds: $FLOWLOG_CACHE_TTL_SECONDS"

log "Validating AWS credentials..."
run_aws sts get-caller-identity >/dev/null

log "Checking EC2 Flow Logs API availability..."
run_aws ec2 describe-flow-logs >/dev/null

log "Discovering VPCs in $region..."
cache_base="${XDG_CACHE_HOME:-$HOME/.cache}/aws-vpc-flowlogs"
mkdir -p "$cache_base"

cache_key_region="$(sanitize_cache_key "$region")"
cache_key_profile="$(sanitize_cache_key "$profile")"
vpc_cache_file="$cache_base/vpcs-${cache_key_profile}-${cache_key_region}.txt"
flowlog_cache_file="$cache_base/flowlogs-${cache_key_profile}-${cache_key_region}.txt"

if cache_is_fresh "$vpc_cache_file" "$VPC_CACHE_TTL_SECONDS"; then
  debug "Using cached VPC data: $vpc_cache_file"
  vpc_rows=$(cat "$vpc_cache_file")
else
  debug "Refreshing VPC cache: $vpc_cache_file"
  vpc_rows=$(run_aws ec2 describe-vpcs --query "Vpcs[*].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" --output text)
  printf "%s\n" "$vpc_rows" > "$vpc_cache_file" || true
fi

if [[ -z "${vpc_rows// }" || "$vpc_rows" == "None" ]]; then
  die "no VPCs found in region $region"
fi

log "Reading Flow Logs once for faster status checks..."
set +e
if (( FLOWLOG_CACHE_TTL_SECONDS > 0 )) && cache_is_fresh "$flowlog_cache_file" "$FLOWLOG_CACHE_TTL_SECONDS"; then
  debug "Using cached Flow Log data: $flowlog_cache_file"
  flowlog_rows=$(cat "$flowlog_cache_file")
  flowlog_rc=0
else
  debug "Refreshing Flow Log cache: $flowlog_cache_file"
  flowlog_rows=$(run_aws ec2 describe-flow-logs \
    --query "FlowLogs[*].[ResourceId,FlowLogId,LogDestinationType,LogDestination,TrafficType,Tags[?Key=='Name']|[0].Value]" \
    --output text 2>/dev/null)
  flowlog_rc=$?
  if [[ $flowlog_rc -eq 0 && $FLOWLOG_CACHE_TTL_SECONDS -gt 0 ]]; then
    printf "%s\n" "$flowlog_rows" > "$flowlog_cache_file" || true
  fi
fi
set -e

log ""
log "Available VPCs:"

declare -a vpc_menu
declare -a row_name
declare -a row_cidr
declare -a row_status
declare -A darktrace_by_vpc
declare -A matching_dest_by_vpc

if [[ $flowlog_rc -eq 0 && -n "${flowlog_rows// }" && "$flowlog_rows" != "None" ]]; then
  while IFS=$'\t' read -r fl_vpc fl_id fl_dest_type fl_dest fl_traffic fl_name; do
    [[ -z "$fl_vpc" || "$fl_vpc" == "None" ]] && continue
    [[ -z "$fl_id" || "$fl_id" == "None" ]] && continue

    if [[ "$fl_name" == "$FLOWLOG_NAME" ]]; then
      darktrace_by_vpc["$fl_vpc"]="$(append_space_list "${darktrace_by_vpc[$fl_vpc]:-}" "$fl_id")"
    fi

    if [[ "$fl_dest_type" == "s3" && "$fl_dest" == "$log_destination" && "$fl_traffic" == "$TRAFFIC_TYPE" ]]; then
      matching_dest_by_vpc["$fl_vpc"]="$(append_space_list "${matching_dest_by_vpc[$fl_vpc]:-}" "$fl_id")"
    fi
  done <<< "$flowlog_rows"
else
  echo "$SCRIPT_NAME: warning: could not prefetch Flow Logs; status checks may be incomplete" >&2
fi

header_no="No"
header_vpc="VPC ID"
header_name="Name"
header_cidr="CIDR"
header_status="darktrace"

no_width=${#header_no}
vpc_width=${#header_vpc}
name_width=${#header_name}
cidr_width=${#header_cidr}
status_width=${#header_status}

index=1
while IFS=$'\t' read -r vpc_id vpc_cidr vpc_name; do
  [[ -z "$vpc_id" || "$vpc_id" == "None" ]] && continue

  [[ "$vpc_name" == "None" || -z "$vpc_name" ]] && vpc_name="-"

  darktrace_ids="${darktrace_by_vpc[$vpc_id]:-}"
  if [[ -n "$darktrace_ids" ]]; then
    darktrace_status="YES ($darktrace_ids)"
  elif [[ $flowlog_rc -ne 0 ]]; then
    darktrace_status="unknown"
  else
    darktrace_status="no"
  fi

  vpc_name="$(clip_text "$vpc_name" 32)"
  darktrace_status="$(clip_text "$darktrace_status" 42)"

  row_name+=("$vpc_name")
  row_cidr+=("$vpc_cidr")
  row_status+=("$darktrace_status")

  (( ${#index} > no_width )) && no_width=${#index}
  (( ${#vpc_id} > vpc_width )) && vpc_width=${#vpc_id}
  (( ${#vpc_name} > name_width )) && name_width=${#vpc_name}
  (( ${#vpc_cidr} > cidr_width )) && cidr_width=${#vpc_cidr}
  (( ${#darktrace_status} > status_width )) && status_width=${#darktrace_status}

  vpc_menu+=("$vpc_id")
  ((index++))
done <<< "$vpc_rows"

separator_len=$((no_width + vpc_width + name_width + cidr_width + status_width + 15))
separator="$(repeat_char "-" "$separator_len")"

echo "$separator"
printf " %-${no_width}s | %-${vpc_width}s | %-${name_width}s | %-${cidr_width}s | %-${status_width}s\n" \
  "$header_no" "$header_vpc" "$header_name" "$header_cidr" "$header_status"
echo "$separator"

for ((i=0; i<${#vpc_menu[@]}; i++)); do
  display_no=$((i + 1))
  printf " %-${no_width}s | %-${vpc_width}s | %-${name_width}s | %-${cidr_width}s | %-${status_width}s\n" \
    "$display_no" "${vpc_menu[$i]}" "${row_name[$i]}" "${row_cidr[$i]}" "${row_status[$i]}"
done

echo "$separator"
echo ""

read -r -p "Choose VPC number: " selected_index
[[ "$selected_index" =~ ^[0-9]+$ ]] || usage_error "selection must be a number"
(( selected_index >= 1 && selected_index <= ${#vpc_menu[@]} )) || usage_error "selection out of range"

vpc_id="${vpc_menu[$((selected_index - 1))]}"
log "Selected VPC: $vpc_id"

selected_darktrace_ids="${darktrace_by_vpc[$vpc_id]:-}"
if [[ $flowlog_rc -ne 0 ]]; then
  echo "$SCRIPT_NAME: warning: could not verify existing darktrace Flow Logs by tag" >&2
elif [[ -n "$selected_darktrace_ids" ]]; then
  log "VPC $vpc_id already has darktrace Flow Log(s): $selected_darktrace_ids"
  log "No action taken."
  exit 0
fi

existing_ids="${matching_dest_by_vpc[$vpc_id]:-}"
if [[ -n "${existing_ids// }" && "$existing_ids" != "None" ]]; then
  log "Flow Log already exists for VPC $vpc_id to $log_destination. Skipping creation."
  log "Existing FlowLogId(s): $existing_ids"
  exit 0
fi

log "Creating VPC Flow Log..."
set +e
create_output=$(run_aws ec2 create-flow-logs \
  --resource-type VPC \
  --resource-ids "$vpc_id" \
  --traffic-type "$TRAFFIC_TYPE" \
  --log-destination-type s3 \
  --log-destination "$log_destination" \
  --destination-options FileFormat=plain-text,PerHourPartition=true \
  --tag-specifications "ResourceType=vpc-flow-log,Tags=[{Key=Name,Value=$FLOWLOG_NAME}]" \
  --query 'FlowLogIds[0]' \
  --output text 2>&1)
create_rc=$?
set -e

if [[ $create_rc -ne 0 ]]; then
  echo "$create_output" >&2
  if grep -qi "Unknown options: --destination-options" <<<"$create_output"; then
    die "your AWS CLI does not support --destination-options; to enforce per-hour partitioning, upgrade AWS CLI and retry"
  fi
  if grep -qi "not a valid taggable resource type" <<<"$create_output"; then
    log "Retrying create without tags and applying Name tag afterwards..."
    created_flow_log_id=$(run_aws ec2 create-flow-logs \
      --resource-type VPC \
      --resource-ids "$vpc_id" \
      --traffic-type "$TRAFFIC_TYPE" \
      --log-destination-type s3 \
      --log-destination "$log_destination" \
      --destination-options FileFormat=plain-text,PerHourPartition=true \
      --query 'FlowLogIds[0]' \
      --output text)

    run_aws ec2 create-tags \
      --resources "$created_flow_log_id" \
      --tags "Key=Name,Value=$FLOWLOG_NAME" >/dev/null

    log "Flow Log created successfully."
    log "FlowLogId: $created_flow_log_id"
    log "Name tag: $FLOWLOG_NAME"
    log "Partition logs by time: Every 1 hour"
    log "Destination: $log_destination"
    exit 0
  fi
  die "failed to create Flow Log; see AWS CLI output above"
fi

created_flow_log_id="$create_output"
log "Flow Log created successfully."
log "FlowLogId: $created_flow_log_id"
log "Name tag: $FLOWLOG_NAME"
log "Partition logs by time: Every 1 hour"
log "Destination: $log_destination"
