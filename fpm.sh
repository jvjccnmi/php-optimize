#!/usr/bin/env bash
# filename: fpm.sh
# PHP-FPM Process Calculator (CLI)
# - Detects total RAM
# - Measures average php-fpm worker size (children "php-fpm: pool ...")
# - Computes available RAM = (Total - Reserved) * (1 - Buffer%)
# - Derives pm.max_children and dynamic pm settings
# - Outputs as table or JSON

set -euo pipefail

VERSION="1.0.0"

# Defaults (can be overridden by flags/env)
RESERVED_GB="${RESERVED_GB:-1}"
BUFFER_PERCENT="${BUFFER_PERCENT:-10}"
POOL_NAME_PATTERN="${POOL_NAME_PATTERN:-php-fpm: pool}"
PM_MODE="${PM_MODE:-dynamic}"           # dynamic | static
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}" # table | json

print_help() {
  cat <<'EOF'
PHP-FPM Process Calculator (CLI)

Usage:
  fpm.sh [options]

Options:
  -r, --reserved <GB>        RAM reserved for OS/other processes (default: 1)
  -b, --buffer <PERCENT>     Safety buffer percent (default: 10)
  -p, --pool-pattern <STR>   ps/command match for php-fpm worker children (default: "php-fpm: pool")
  --pm <dynamic|static>      Compute settings for pm mode (default: dynamic)
  --json                     Output JSON instead of table
  -h, --help                 Show help
  -v, --version              Show version

Examples:
  ./fpm.sh
  ./fpm.sh -r 0.25 -b 10
  ./fpm.sh --pm static
  ./fpm.sh --json
  RESERVED_GB=0.5 BUFFER_PERCENT=15 ./fpm.sh

Notes:
- For pm=static, only pm.max_children is relevant; spare/start values are ignored.
- Re-run under typical load to get a realistic worker MB average.
- Adjust --pool-pattern if your process titles differ, e.g. "php-fpm: pool www".
EOF
}

print_version() {
  echo "fpm.sh v${VERSION}"
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--reserved)
      [[ $# -ge 2 ]] || { echo "Error: --reserved requires a value" >&2; exit 2; }
      RESERVED_GB="$2"; shift 2 ;;
    -b|--buffer)
      [[ $# -ge 2 ]] || { echo "Error: --buffer requires a value" >&2; exit 2; }
      BUFFER_PERCENT="$2"; shift 2 ;;
    -p|--pool-pattern)
      [[ $# -ge 2 ]] || { echo "Error: --pool-pattern requires a value" >&2; exit 2; }
      POOL_NAME_PATTERN="$2"; shift 2 ;;
    --pm)
      [[ $# -ge 2 ]] || { echo "Error: --pm requires dynamic|static" >&2; exit 2; }
      PM_MODE="$2"; shift 2 ;;
    --json)
      OUTPUT_FORMAT="json"; shift ;;
    -h|--help)
      print_help; exit 0 ;;
    -v|--version)
      print_version; exit 0 ;;
    *)
      echo "Error: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2 ;;
  esac
done

# Validation
is_number() { awk -v x="$1" 'BEGIN{ if (x ~ /^[0-9]*\.?[0-9]+$/) exit 0; else exit 1 }'; }
is_percent() { awk -v x="$1" 'BEGIN{ if (x ~ /^[0-9]*\.?[0-9]+$/ && x>=0) exit 0; else exit 1 }'; }

is_number "$RESERVED_GB" || { echo "Error: reserved must be a non-negative number" >&2; exit 2; }
is_percent "$BUFFER_PERCENT" || { echo "Error: buffer must be a non-negative number" >&2; exit 2; }

case "$PM_MODE" in
  dynamic|static) ;;
  *) echo "Error: --pm must be dynamic or static" >&2; exit 2 ;;
esac

get_total_gb() {
  if command -v free >/dev/null 2>&1; then
    local mib
    mib=$(free -m | awk '/^Mem:/ {print $2}')
    awk -v mib="$mib" 'BEGIN { printf "%.2f", mib/1024 }'
  else
    echo "Error: Unable to detect total RAM on this OS." >&2
    exit 1
  fi
}

get_worker_mb_avg() {
  # Use ps size (KB). Average only children matching pool pattern.
  local avg
  avg=$(ps -eo size,command --sort -size \
    | awk -v pat="$POOL_NAME_PATTERN" '
      $0 ~ pat { sum += $1; count += 1 }
      END {
        if (count == 0) { exit 10 }
        printf "%.2f\n", sum / count / 1024.0
      }' \
    || true)

  if [[ -z "${avg:-}" ]]; then
    echo "Error: Could not find php-fpm worker processes matching pattern: $POOL_NAME_PATTERN" >&2
    exit 3
  fi
  echo "$avg"
}

TOTAL_GB=$(get_total_gb)
WORKER_MB=$(get_worker_mb_avg)

# Compute available RAM (clamped to 0)
AVAILABLE_GB=$(awk -v t="$TOTAL_GB" -v r="$RESERVED_GB" -v b="$BUFFER_PERCENT" \
  'BEGIN {
    avail = (t - r) * (1.0 - b/100.0);
    if (avail < 0) avail = 0;
    printf "%.2f", avail
  }')

AVAILABLE_MB=$(awk -v g="$AVAILABLE_GB" 'BEGIN { printf "%.0f", g*1024 }')

MAX_CHILDREN=$(awk -v avail="$AVAILABLE_MB" -v w="$WORKER_MB" \
  'BEGIN {
    if (w <= 0.0) { print 0; exit }
    m = int(avail / w);
    if (m < 0) m = 0;
    print m
  }')

# Dynamic suggestions
MIN_SPARE=$(awk -v mc="$MAX_CHILDREN" 'BEGIN {
  v = int(mc * 0.10);
  if (v < 1) v = 1;
  print v
}')
MAX_SPARE=$(awk -v mc="$MAX_CHILDREN" -v minsp="$MIN_SPARE" 'BEGIN {
  v = int(mc * 0.30);
  if (v <= minsp) v = minsp + 1;
  print v
}')
START_SERVERS=$(awk -v minsp="$MIN_SPARE" -v maxsp="$MAX_SPARE" 'BEGIN {
  print int(minsp + (maxsp - minsp)/2)
}')

print_table() {
  local pm="$1"
  printf "%s\n" "------------------------------------------------------------"
  printf "%s\n" "PHP-FPM Process Calculator (CLI)"
  printf "%s\n" "------------------------------------------------------------"
  printf "%-24s | %s\n" "Total RAM (GB)"        "$TOTAL_GB"
  printf "%-24s | %s\n" "Reserved RAM (GB)"     "$RESERVED_GB"
  printf "%-24s | %s\n" "RAM Buffer (%)"        "$BUFFER_PERCENT"
  printf "%-24s | %s\n" "Worker Process (MB)"   "$WORKER_MB"
  printf "%-24s | %s\n" "Available RAM (GB)"    "$AVAILABLE_GB"
  printf "%-24s | %s\n" "Available RAM (MB)"    "$AVAILABLE_MB"
  printf "%s\n" "------------------------------------------------------------"
  printf "%-24s | %s\n" "pm.mode (selected)"    "$pm"
  printf "%-24s | %s\n" "pm.max_children"       "$MAX_CHILDREN"
  if [[ "$pm" == "dynamic" ]]; then
    printf "%-24s | %s\n" "pm.start_servers"      "$START_SERVERS"
    printf "%-24s | %s\n" "pm.min_spare_servers"  "$MIN_SPARE"
    printf "%-24s | %s\n" "pm.max_spare_servers"  "$MAX_SPARE"
  fi
  printf "%s\n" "------------------------------------------------------------"
  printf "\n# Suggested php-fpm pool config\n"
  if [[ "$pm" == "dynamic" ]]; then
    cat <<EOF
pm = dynamic
pm.max_children = $MAX_CHILDREN
pm.start_servers = $START_SERVERS
pm.min_spare_servers = $MIN_SPARE
pm.max_spare_servers = $MAX_SPARE
EOF
  else
    cat <<EOF
pm = static
pm.max_children = $MAX_CHILDREN
# (spare/start values are ignored in static mode)
EOF
  fi
}

print_json() {
  cat <<EOF
{
  "total_gb": $TOTAL_GB,
  "reserved_gb": $RESERVED_GB,
  "buffer_percent": $BUFFER_PERCENT,
  "worker_mb_avg": $WORKER_MB,
  "available_gb": $AVAILABLE_GB,
  "available_mb": $AVAILABLE_MB,
  "pm_mode": "$(printf "%s" "$PM_MODE")",
  "pm": {
    "max_children": $MAX_CHILDREN$( [[ "$PM_MODE" == "dynamic" ]] && printf ",\n    \"start_servers\": %s,\n    \"min_spare_servers\": %s,\n    \"max_spare_servers\": %s" "$START_SERVERS" "$MIN_SPARE" "$MAX_SPARE" )
  }
}
EOF
}

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  print_json
else
  print_table "$PM_MODE"
fi
