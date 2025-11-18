#!/usr/bin/env bash
# filename: frankenphp.sh
# FrankenPHP Worker Calculator (CLI)
# - Detects total RAM and CPU count
# - Measures average FrankenPHP worker size (processes matching "frankenphp")
# - Computes available RAM = (Total - Reserved) * (1 - Buffer%)
# - Derives optimal worker count and thread settings
# - Outputs as table or JSON

set -euo pipefail

VERSION="1.0.0"

# Defaults (can be overridden by flags/env)
RESERVED_GB="${RESERVED_GB:-0.4}"
BUFFER_PERCENT="${BUFFER_PERCENT:-10}"
PROCESS_PATTERN="${PROCESS_PATTERN:-frankenphp}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}" # table | json
WORKER_MULTIPLIER="${WORKER_MULTIPLIER:-2}"  # workers per CPU (FrankenPHP recommends 2-4x)
OVERHEAD_MB="${OVERHEAD_MB:-auto}"  # auto | specific MB value

print_help() {
  cat <<'EOF'
FrankenPHP Worker Calculator (CLI)

Usage:
  frankenphp.sh [options]

Options:
  -r, --reserved <GB>        RAM reserved for OS/other processes (default: 0.4)
  -b, --buffer <PERCENT>     Safety buffer percent (default: 10)
  -p, --process-pattern <STR> ps/command match for FrankenPHP processes (default: "frankenphp")
  -m, --multiplier <NUM>     Worker multiplier per CPU (default: 2, FrankenPHP recommends 2-4)
  -o, --overhead <MB|auto>   Memory overhead in MB or 'auto' to detect (default: auto)
  --json                     Output JSON instead of table
  -h, --help                 Show help
  -v, --version              Show version

Examples:
  ./frankenphp.sh
  ./frankenphp.sh -r 0.2 -b 15
  ./frankenphp.sh -m 3
  ./frankenphp.sh -o 200
  ./frankenphp.sh --overhead auto
  ./frankenphp.sh --json
  RESERVED_GB=0.5 BUFFER_PERCENT=10 OVERHEAD_MB=150 ./frankenphp.sh

Notes:
- FrankenPHP uses threads (not processes), sharing memory more efficiently than PHP-FPM
- Worker mode keeps Laravel in memory, dramatically improving performance
- Recommended: 2-4 workers per CPU for optimal performance
- num_threads = 2 × num_workers (handles worker + classic PHP requests)
- max_threads = 2 × num_threads (burst capacity)
- Re-run under typical load to get realistic worker memory usage
- Adjust --multiplier based on your application's I/O vs CPU characteristics

Overhead Detection (--overhead auto):
- Detects OPcache memory (opcache.memory_consumption)
- Assumes 100 MB for caches/runtime if OPcache not found
- For Laravel+SQLite: typically 250-350 MB (OPcache + SQLite + Caddy)
- For minimal apps: typically 100-150 MB (just OPcache + Caddy)
- Override with specific MB value if auto-detection is incorrect
EOF
}

print_version() {
  echo "frankenphp.sh v${VERSION}"
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
    -p|--process-pattern)
      [[ $# -ge 2 ]] || { echo "Error: --process-pattern requires a value" >&2; exit 2; }
      PROCESS_PATTERN="$2"; shift 2 ;;
    -m|--multiplier)
      [[ $# -ge 2 ]] || { echo "Error: --multiplier requires a value" >&2; exit 2; }
      WORKER_MULTIPLIER="$2"; shift 2 ;;
    -o|--overhead)
      [[ $# -ge 2 ]] || { echo "Error: --overhead requires a value (MB or 'auto')" >&2; exit 2; }
      OVERHEAD_MB="$2"; shift 2 ;;
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
is_number "$WORKER_MULTIPLIER" || { echo "Error: multiplier must be a non-negative number" >&2; exit 2; }

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

get_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif [[ -f /proc/cpuinfo ]]; then
    grep -c ^processor /proc/cpuinfo
  else
    echo "1"
  fi
}

get_worker_mb_avg() {
  local avg
  avg=$(ps aux | awk -v pat="$PROCESS_PATTERN" '
    $0 ~ pat && $0 !~ /awk/ { sum += $6; count += 1 }
    END {
      if (count == 0) { exit 10 }
      printf "%.2f\n", sum / count / 1024.0
    }' || true)

  if [[ -z "${avg:-}" ]]; then
    echo "Warning: Could not find FrankenPHP processes matching pattern: $PROCESS_PATTERN" >&2
    echo "Using estimated 50 MB per worker (typical for Laravel worker mode)" >&2
    echo "50.00"
  else
    echo "$avg"
  fi
}

get_overhead_mb() {
  local overhead_setting="$1"

  if [[ "$overhead_setting" != "auto" ]]; then
    echo "$overhead_setting"
    return
  fi

  local total_overhead=0

  # Detect OPcache memory (if PHP available)
  if command -v php >/dev/null 2>&1; then
    local opcache_mem
    opcache_mem=$(php -r "echo ini_get('opcache.memory_consumption');" 2>/dev/null || echo "0")
    if [[ "$opcache_mem" -gt 0 ]]; then
      total_overhead=$((total_overhead + opcache_mem / 1048576))  # Convert bytes to MB
    else
      # OPcache not configured, assume 128 MB default
      total_overhead=$((total_overhead + 128))
    fi
  else
    # PHP not found, assume 128 MB for OPcache
    total_overhead=$((total_overhead + 128))
  fi

  # Add Caddy/FrankenPHP runtime overhead (fixed estimate)
  total_overhead=$((total_overhead + 50))

  # Users can override with -o flag if they know their specific overhead
  total_overhead=$((total_overhead + 100))

  echo "$total_overhead"
}

TOTAL_GB=$(get_total_gb)
CPU_COUNT=$(get_cpu_count)
WORKER_MB=$(get_worker_mb_avg)
OVERHEAD_MB=$(get_overhead_mb "$OVERHEAD_MB")

# Compute available RAM (clamped to 0)
AVAILABLE_GB=$(awk -v t="$TOTAL_GB" -v r="$RESERVED_GB" -v b="$BUFFER_PERCENT" \
  'BEGIN {
    avail = (t - r) * (1.0 - b/100.0);
    if (avail < 0) avail = 0;
    printf "%.2f", avail
  }')

AVAILABLE_MB=$(awk -v g="$AVAILABLE_GB" 'BEGIN { printf "%.0f", g*1024 }')

# Subtract overhead from available RAM
USABLE_MB=$(awk -v avail="$AVAILABLE_MB" -v overhead="$OVERHEAD_MB" \
  'BEGIN {
    usable = avail - overhead;
    if (usable < 0) usable = 0;
    printf "%.0f", usable
  }')

# Calculate workers based on CPU count and multiplier
CPU_BASED_WORKERS=$(awk -v cpu="$CPU_COUNT" -v mult="$WORKER_MULTIPLIER" \
  'BEGIN { print int(cpu * mult) }')

# Calculate workers based on available memory
MEMORY_BASED_WORKERS=$(awk -v usable="$USABLE_MB" -v w="$WORKER_MB" \
  'BEGIN {
    if (w <= 0.0) { print 0; exit }
    m = int(usable / w);
    if (m < 0) m = 0;
    print m
  }')

# Use the MINIMUM of CPU-based and memory-based calculations (most conservative)
NUM_WORKERS=$(awk -v cpu="$CPU_BASED_WORKERS" -v mem="$MEMORY_BASED_WORKERS" \
  'BEGIN {
    if (cpu < mem) print cpu;
    else print mem;
  }')

# Ensure at least 2 workers minimum
NUM_WORKERS=$(awk -v w="$NUM_WORKERS" 'BEGIN {
  if (w < 2) w = 2;
  print w
}')

# Calculate thread settings
NUM_THREADS=$(awk -v w="$NUM_WORKERS" 'BEGIN { print w * 2 }')
MAX_THREADS=$(awk -v t="$NUM_THREADS" 'BEGIN { print t * 2 }')

# Calculate estimated memory usage
ESTIMATED_WORKER_MEMORY=$(awk -v w="$NUM_WORKERS" -v mb="$WORKER_MB" \
  'BEGIN { printf "%.0f", w * mb }')

ESTIMATED_TOTAL_MEMORY=$(awk -v worker="$ESTIMATED_WORKER_MEMORY" -v overhead="$OVERHEAD_MB" \
  'BEGIN { printf "%.0f", worker + overhead }')

ESTIMATED_TOTAL_GB=$(awk -v mb="$ESTIMATED_TOTAL_MEMORY" \
  'BEGIN { printf "%.2f", mb / 1024 }')

print_table() {
  printf "%s\n" "------------------------------------------------------------"
  printf "%s\n" "FrankenPHP Worker Calculator (CLI)"
  printf "%s\n" "------------------------------------------------------------"
  printf "%-28s | %s\n" "Total RAM (GB)" "$TOTAL_GB"
  printf "%-28s | %s\n" "Reserved RAM (GB)" "$RESERVED_GB"
  printf "%-28s | %s\n" "RAM Buffer (%)" "$BUFFER_PERCENT"
  printf "%-28s | %s\n" "CPU Count" "$CPU_COUNT"
  printf "%-28s | %s\n" "Worker Multiplier (per CPU)" "$WORKER_MULTIPLIER"
  printf "%-28s | %s\n" "Worker Process (MB)" "$WORKER_MB"
  printf "%-28s | %s\n" "Overhead (MB)" "$OVERHEAD_MB"
  printf "%-28s | %s\n" "Available RAM (GB)" "$AVAILABLE_GB"
  printf "%-28s | %s\n" "Available RAM (MB)" "$AVAILABLE_MB"
  printf "%-28s | %s\n" "Usable for Workers (MB)" "$USABLE_MB"
  printf "%s\n" "------------------------------------------------------------"
  printf "%-28s | %s\n" "CPU-based workers" "$CPU_BASED_WORKERS"
  printf "%-28s | %s\n" "Memory-based workers" "$MEMORY_BASED_WORKERS"
  printf "%-28s | %s\n" "Recommended workers" "$NUM_WORKERS (conservative)"
  printf "%-28s | %s\n" "num_threads" "$NUM_THREADS (2x workers)"
  printf "%-28s | %s\n" "max_threads" "$MAX_THREADS (burst capacity)"
  printf "%s\n" "------------------------------------------------------------"
  printf "%-28s | %s MB (%.2f GB)\n" "Estimated worker memory" "$ESTIMATED_WORKER_MEMORY" "$(awk -v m="$ESTIMATED_WORKER_MEMORY" 'BEGIN {printf "%.2f", m/1024}')"
  printf "%-28s | %s MB (%.2f GB)\n" "Estimated total memory" "$ESTIMATED_TOTAL_MEMORY" "$ESTIMATED_TOTAL_GB"
  printf "%s\n" "------------------------------------------------------------"

  printf "\n# Suggested Caddyfile configuration\n"
  cat <<EOF
{
  frankenphp {
    worker {
      file "/path/to/your/frankenphp-worker.php"
      num $NUM_WORKERS
    }
    num_threads $NUM_THREADS
    max_threads $MAX_THREADS
  }
}

:8080 {
  route {
    root * "/path/to/your/public"
    encode zstd br gzip

    php_server {
      index frankenphp-worker.php
      try_files {path} frankenphp-worker.php
      resolve_root_symlink
      num_threads $NUM_THREADS
    }
  }
}
EOF
}

print_json() {
  cat <<EOF
{
  "total_gb": $TOTAL_GB,
  "reserved_gb": $RESERVED_GB,
  "buffer_percent": $BUFFER_PERCENT,
  "cpu_count": $CPU_COUNT,
  "worker_multiplier": $WORKER_MULTIPLIER,
  "worker_mb_avg": $WORKER_MB,
  "overhead_mb": $OVERHEAD_MB,
  "available_gb": $AVAILABLE_GB,
  "available_mb": $AVAILABLE_MB,
  "usable_mb": $USABLE_MB,
  "cpu_based_workers": $CPU_BASED_WORKERS,
  "memory_based_workers": $MEMORY_BASED_WORKERS,
  "recommended_workers": $NUM_WORKERS,
  "num_threads": $NUM_THREADS,
  "max_threads": $MAX_THREADS,
  "estimated_memory": {
    "worker_mb": $ESTIMATED_WORKER_MEMORY,
    "total_mb": $ESTIMATED_TOTAL_MEMORY,
    "total_gb": $ESTIMATED_TOTAL_GB
  },
  "caddyfile": {
    "num": $NUM_WORKERS,
    "num_threads": $NUM_THREADS,
    "max_threads": $MAX_THREADS
  }
}
EOF
}

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  print_json
else
  print_table
fi
