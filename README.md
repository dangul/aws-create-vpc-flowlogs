# aws-vpc-flowlogs

Create a VPC Flow Log to a region-specific S3 bucket for Darktrace.

Region-to-S3 mapping is stored in a separate config file: `region-s3-buckets.conf`.

## What this script does

- Uses AWS CLI with your local AWS config profile (`--profile`).
- Discovers VPCs in the selected region and lets you choose which VPC to use.
- Shows whether each VPC already has a Flow Log with tag `Name=darktrace`.
- Creates a VPC Flow Log with:
  - Traffic type: `ALL`
  - Destination type: `s3`
  - Partition logs by time: `Every 1 hour`
  - Hive-compatible partitions: `disabled`
  - Tag `Name=darktrace`
- Is idempotent: if a matching flow log already exists for the VPC and destination, it skips creation.
- Uses a short local cache (default 30 seconds) for VPC and Flow Log lookups to speed up repeated runs.
  - VPC cache is enabled by default.
  - Flow Log cache is disabled by default to avoid stale status right after creation.

## Script

`create-vpc-flowlog.sh`

## Usage

```bash
chmod +x create-vpc-flowlog.sh
./create-vpc-flowlog.sh --region eu-north-1 --profile myprofile
```

Short flags are also supported:

```bash
./create-vpc-flowlog.sh -r eu-north-1 -p myprofile
```

Optional flags:

- `-q`, `--quiet` for less progress output
- `-v`, `--verbose` for cache/debug details
- `-h`, `--help` for usage

When run, the script prints a numbered VPC list with darktrace status and prompts:

```text
Choose VPC number:
```

## Region to S3 destination mapping

Mapping is loaded from `region-s3-buckets.conf` using this format:

```conf
region=arn:aws:s3:::bucket-name
```

Example:

```conf
eu-north-1=arn:aws:s3:::demo-flowlogs-xyz-eu-north-1
```

## Notes

- The script requires AWS CLI to be installed and configured.
- Your IAM identity must have permission to call EC2 Flow Logs APIs for the selected VPC.
- Optional: set `CACHE_TTL_SECONDS` to control cache duration, for example:

```bash
VPC_CACHE_TTL_SECONDS=60 ./create-vpc-flowlog.sh --region eu-north-1 --profile myprofile
```

Optional legacy variable (still supported for VPC cache):

```bash
CACHE_TTL_SECONDS=60 ./create-vpc-flowlog.sh --region eu-north-1 --profile myprofile
```

If you want faster repeated runs and can accept brief delay in status updates, enable Flow Log cache too:

```bash
FLOWLOG_CACHE_TTL_SECONDS=15 ./create-vpc-flowlog.sh --region eu-north-1 --profile myprofile
```

Use an alternate mapping file if needed:

```bash
REGION_MAP_FILE=./my-region-map.conf ./create-vpc-flowlog.sh --region eu-north-1 --profile myprofile
```

## Validate script

```bash
shellcheck -s bash create-vpc-flowlog.sh
```
