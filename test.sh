#!/usr/bin/env bash
# filename: test.sh
# PHP Load Testing Script using oha
# Tests your configuration under various loads

set -euo pipefail

VERSION="1.0.0"

# Defaults
URL="${URL:-http://localhost}"
DURATION="${DURATION:-30}"
WORKERS="${WORKERS:-10}"
MAX_WORKERS="${MAX_WORKERS:-50}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-summary}"  # summary | json

print_help() {
  cat <<'EOF'
PHP-FPM Load Testing Script

Usage:
  ./test-fpm.sh [options]

Options:
  -u, --url <URL>            Target URL to test (default: http://localhost)
  -d, --duration <SECONDS>   Test duration in seconds (default: 30)
  -w, --workers <NUM>        Number of concurrent workers (default: 10)
  -m, --max <NUM>            Maximum workers from fpm.sh (default: 51)
  --progressive              Run progressive load test (10% -> 100% of max)
  --json                     Output JSON format
  -h, --help                 Show help
  -v, --version              Show version

Examples:
  # Basic test with 10 concurrent requests
  ./test.sh -u http://localhost/index.php

  # Test with 25 workers for 60 seconds
  ./test.sh -u http://localhost/test.php -w 25 -d 60

  # Progressive load test (ramps up to max_children)
  ./test.sh -u http://localhost/index.php --progressive -m 51

  # Stress test at max capacity
  ./test.sh -u http://localhost/index.php -w 51 -d 120

Notes:
- Use --progressive to find your breaking point
- Watch `ps aux | grep php-fpm` during tests
- Monitor memory with `watch -n 1 free -m`
- Set -m to your pm.max_children value for accurate testing
EOF
}

print_version() {
  echo "test.sh v${VERSION}"
}

run_single_test() {
  local url="$1"
  local workers="$2"
  local duration="$3"
  local format="$4"

  echo "========================================"
  echo "Testing with $workers concurrent workers"
  echo "Duration: ${duration}s | URL: $url"
  echo "========================================"

  if [[ "$format" == "json" ]]; then
    oha -z "${duration}s" -c "$workers" --json "$url"
  else
    oha -z "${duration}s" -c "$workers" "$url"
  fi
}

run_progressive_test() {
  local url="$1"
  local max_workers="$2"
  local duration="$3"

  echo "========================================"
  echo "Progressive Load Test"
  echo "Ramping from 10% to 100% of max_children ($max_workers)"
  echo "========================================"

  local levels=(10 25 50 75 100)

  for percent in "${levels[@]}"; do
    local workers=$(awk -v max="$max_workers" -v pct="$percent" 'BEGIN {
      w = int(max * pct / 100);
      if (w < 1) w = 1;
      print w
    }')

    echo ""
    echo "----------------------------------------"
    echo "Testing at $percent% capacity ($workers workers)"
    echo "----------------------------------------"

    oha -z "${duration}s" -c "$workers" "$url"

    if [[ "$percent" -lt 100 ]]; then
      echo ""
      echo "Cooling down for 5 seconds..."
      sleep 5
    fi
  done

  echo ""
  echo "========================================"
  echo "Progressive test complete!"
  echo "Review results above to find optimal load"
  echo "========================================"
}

# Parse args
PROGRESSIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)
      [[ $# -ge 2 ]] || { echo "Error: --url requires a value" >&2; exit 2; }
      URL="$2"; shift 2 ;;
    -d|--duration)
      [[ $# -ge 2 ]] || { echo "Error: --duration requires a value" >&2; exit 2; }
      DURATION="$2"; shift 2 ;;
    -w|--workers)
      [[ $# -ge 2 ]] || { echo "Error: --workers requires a value" >&2; exit 2; }
      WORKERS="$2"; shift 2 ;;
    -m|--max)
      [[ $# -ge 2 ]] || { echo "Error: --max requires a value" >&2; exit 2; }
      MAX_WORKERS="$2"; shift 2 ;;
    --progressive)
      PROGRESSIVE=true; shift ;;
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

# Check if oha is installed
if ! command -v oha >/dev/null 2>&1; then
  echo "Error: oha is not installed" >&2
  echo "" >&2
  echo "Install with:" >&2
  echo "  macOS:   brew install oha" >&2
  echo "  Linux:   cargo install oha" >&2
  echo "  Or download from: https://github.com/hatoo/oha" >&2
  exit 1
fi

# Validate URL
if [[ ! "$URL" =~ ^https?:// ]]; then
  echo "Error: URL must start with http:// or https://" >&2
  exit 2
fi

# Run tests
if [[ "$PROGRESSIVE" == true ]]; then
  run_progressive_test "$URL" "$MAX_WORKERS" "$DURATION"
else
  run_single_test "$URL" "$WORKERS" "$DURATION" "$OUTPUT_FORMAT"
fi
