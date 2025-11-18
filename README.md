# PHP/FrankenPHP Process Calculators

Two calculators to help you optimize your PHP application server configuration based on available RAM and CPU. Created for optimizing PHP applications on resource-constrained servers.

## Quick Install

```bash
# Download all scripts
curl -fsSL https://raw.githubusercontent.com/eznix86/php-optimize/main/fpm.sh -o fpm.sh
curl -fsSL https://raw.githubusercontent.com/eznix86/php-optimize/main/frankenphp.sh -o frankenphp.sh
curl -fsSL https://raw.githubusercontent.com/eznix86/php-optimize/main/test.sh -o test.sh
chmod +x fpm.sh frankenphp.sh test.sh

# Or with wget
wget https://raw.githubusercontent.com/eznix86/php-optimize/main/fpm.sh
wget https://raw.githubusercontent.com/eznix86/php-optimize/main/frankenphp.sh
wget https://raw.githubusercontent.com/eznix86/php-optimize/main/test.sh
chmod +x fpm.sh frankenphp.sh test.sh
```

## Scripts

### 1. `fpm.sh` - PHP-FPM Calculator
For traditional PHP-FPM + Nginx/Caddy setups.

### 2. `frankenphp.sh` - FrankenPHP Calculator
For modern FrankenPHP (Caddy + PHP workers) setups.

### 3. `test.sh` - Load Testing Tool
For performance testing your configuration.

---

## FrankenPHP Calculator (`frankenphp.sh`)

### Usage

```bash
# Basic usage (auto-detect everything)
./frankenphp.sh

# Custom configuration
./frankenphp.sh -r 0.2 -b 15 -m 3

# Specify overhead manually
./frankenphp.sh -o 250

# JSON output
./frankenphp.sh --json
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-r, --reserved <GB>` | RAM reserved for OS | 0.4 GB |
| `-b, --buffer <PERCENT>` | Safety buffer percentage | 10% |
| `-m, --multiplier <NUM>` | Workers per CPU | 2 |
| `-o, --overhead <MB\|auto>` | Memory overhead | auto |
| `-p, --process-pattern` | Process name to match | "frankenphp" |
| `--json` | JSON output | table |

### Overhead Detection (`-o auto`)

The script automatically detects memory overhead from:

1. **OPcache** - Auto-detected from `opcache.memory_consumption`
2. **Caddy/FrankenPHP runtime** - Fixed estimate (~50 MB)
3. **Generic cache/database** - Conservative estimate (~100 MB)

**Total auto-detected overhead:** Typically 150-350 MB depending on your stack

### Manual Overhead Examples

```bash
# Minimal app (OPcache + Caddy only)
./frankenphp.sh -o 150

# Laravel + SQLite (OPcache + SQLite cache/mmap + Caddy)
./frankenphp.sh -o 306

# Laravel + MySQL + Redis
./frankenphp.sh -o 400

# Let script auto-detect (recommended)
./frankenphp.sh -o auto
```

### Overhead Breakdown by Stack (example)

| Stack | OPcache | Database | Cache | Caddy | Total |
|-------|---------|----------|-------|-------|-------|
| **Minimal PHP app** | 128 MB | - | - | 50 MB | ~180 MB |
| **Laravel + SQLite** | 128 MB | 128 MB | - | 50 MB | ~306 MB |
| **Laravel + MySQL** | 128 MB | 200 MB | - | 50 MB | ~378 MB |
| **Laravel + MySQL + Redis** | 128 MB | 200 MB | 64 MB | 50 MB | ~442 MB |

### Output Example

```
------------------------------------------------------------
FrankenPHP Worker Calculator (CLI)
------------------------------------------------------------
Total RAM (GB)               | 0.94
Reserved RAM (GB)            | 0.20
RAM Buffer (%)               | 10
CPU Count                    | 1
Worker Multiplier (per CPU)  | 2
Worker Process (MB)          | 50.00
Overhead (MB)                | 278 (auto-detected)
Available RAM (GB)           | 0.67
Available RAM (MB)           | 686
Usable for Workers (MB)      | 408
------------------------------------------------------------
CPU-based workers            | 2
Memory-based workers         | 8
Recommended workers          | 2 (conservative)
num_threads                  | 4 (2x workers)
max_threads                  | 8 (burst capacity)
------------------------------------------------------------
Estimated worker memory      | 100 MB (0.10 GB)
Estimated total memory       | 378 MB (0.37 GB)
------------------------------------------------------------

# Suggested Caddyfile configuration
{
  frankenphp {
    worker {
      file "/path/to/your/frankenphp-worker.php"
      num 2
    }
    num_threads 4
    max_threads 8
  }
}
```

---

## PHP-FPM Calculator (`fpm.sh`)

### Usage

```bash
# Basic usage
./fpm.sh

# Custom configuration
./fpm.sh -r 0.5 -b 10

# Static mode
./fpm.sh --pm static

# JSON output
./fpm.sh --json
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `-r, --reserved <GB>` | RAM reserved for OS | 1 GB |
| `-b, --buffer <PERCENT>` | Safety buffer percentage | 10% |
| `-p, --pool-pattern` | Process pattern to match | "php-fpm: pool" |
| `--pm <dynamic\|static>` | PM mode | dynamic |
| `--json` | JSON output | table |

### Output Example

```
------------------------------------------------------------
PHP-FPM Process Calculator (CLI)
------------------------------------------------------------
Total RAM (GB)           | 0.94
Reserved RAM (GB)        | 0.5
RAM Buffer (%)           | 10
Worker Process (MB)      | 7.93
Available RAM (GB)       | 0.40
Available RAM (MB)       | 410
------------------------------------------------------------
pm.mode (selected)       | dynamic
pm.max_children          | 51
pm.start_servers         | 10
pm.min_spare_servers     | 5
pm.max_spare_servers     | 15
------------------------------------------------------------

# Suggested php-fpm pool config
pm = dynamic
pm.max_children = 51
pm.start_servers = 10
pm.min_spare_servers = 5
pm.max_spare_servers = 15
```

---

## Performance Testing

Use `test.sh` to load test your configuration:

```bash
# Test with 51 concurrent workers for 60 seconds
./test.sh -w 51 -u http://localhost/login -d 60

# Progressive load test (10% → 100%)
./test.sh -u http://localhost/login --progressive -m 51
```

---

## Real-World Example: 1GB Server

### Setup
- Server: 1 CPU, 1GB RAM
- Stack: Laravel + SQLite + FrankenPHP
- Worker size: ~50 MB under load

### Configuration Process

```bash
# 1. Run the calculator
./frankenphp.sh -r 0.2 -b 10 -o auto

# Output recommends:
# - 6 workers
# - num_threads: 12
# - max_threads: 24

# 2. Apply to Caddyfile
# 3. Load test
./test-fpm.sh -w 51 -u http://localhost/login -d 60

# 4. Monitor memory
watch -n 2 'free -m'
```

### Results
- **Throughput:** 150-160 req/s
- **Response time:** 300-350ms average
- **Memory usage:** 400-500 MB stable
- **Uptime:** 100% (no OOM kills)

### Comparison: PHP-FPM vs FrankenPHP

| Metric | PHP-FPM | FrankenPHP | Winner |
|--------|---------|------------|--------|
| **Requests/sec** | 81 | 156 | FrankenPHP (92% more) |
| **Avg response** | 120ms | 65ms | FrankenPHP (46% faster) |
| **Memory usage** | 441 MB | 459 MB | PHP-FPM (4% less) |
| **Setup complexity** | Medium | Medium | Tie |

**Recommendation:** FrankenPHP for better performance, PHP-FPM for maximum stability.

---

### Credit:

Inspiration from: https://www.damianoperri.it/public/phpCalculator/
