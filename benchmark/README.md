# Baseline TCP & UDP syslog message benchark testing

## Run the benchmark

### Docker

Build:

```bash
docker build -f Dockerfile-benchmark.test -t jpvriel/syslog_benchmark:0.0.1 -t jpvriel/syslog_benchmark:latest .
```

Run:

```bash
docker run -v "$(pwd)/test":/tmp/test --rm -it jpvriel/syslog_benchmark
```

Where test is a bind mounted volume used for test data and results.

### Local

To run on your own system locally (assuming dependencies are met), execute the bash script: `usr/local/bin/test_syslog_perf.sh`.

## Overview

A set of benchmarks aimed at answering the following primary questions:

- Is it possible to handle a larger number of TCP clients? E.g.
  - Production scenario's with many TCP clients led to reliability issues with many session open failures.
- Increase message processing rate (also known as events per second/EPS). E.g.:
  - Attempt to use more workers to access spare CPU cores or threads.
  - Attempt larger batch sizes to improve efficiency.

Secondary questions were:

- How much overhead does splitting into multiple rule-sets and queues cause versus just using the default main Q?
- Is it possible to get TCP input throughput to run as fast as UDP (even if it requires more resources)?

Benchmark choices for number of parallel connections and rsyslog worker threads will depend of parallel threads available from a platform's CPU.

## Benchmark choices/parameters

Adjust and export environment variables to control override default choices which can be examined by reading `test_syslog_perf.sh`. Notable defaults are effectively.

```bash
N_CLIENTS=$(( $(nproc) / 2 ))
N_MESSAGES=100000
N_REPITITIONS=3
```

## Benchmark dependencies

Benchmarks should work in most reasonable bash and python environments. However, it's only been developed on Ubuntu 18.04 LTS with python 3.7.3 (from Anaconda) and tested with the python 3.7 jessie (debian) container image.

Binaries needed are:

- `nc` : BSD netcat (to simulate a dummy syslog service).
- `time` : The actual `/usr/bin/time` utility, not the bash builtin.
- `kill`
- `bc`
- `jq`
- `pgrep`

Most of the modules used are packaged with a standard python install. Extra python modules needed are:

- `pandas`

The extra `sleep` bash builtin is suggested if messages will be generated with a 'sleep' delay. Most systems use an external system call, e.g. `/bin/sleep`, which adds too much overhead with short sub-second sleep delays. However, the default is to generate messages with no sleep, so this isn't needed until `S_DELAY` is set.

## Results and observations

Tests done on a Intel i7-4810MQ (4 core/8 hyper-thread) with Ubuntu 18.04 LTS and Linux Kernel 4.18.

CPU related counters for user and system were considered for comparative purposes.

### TCP client sessions

TODO

### Message throughput

TODO

### Multiple rulesets and queues vs default main queue

TODO

## Benchmark script

`./test_syslog_perf.sh` is a once-off bash test script to loop around multiple test interations. By default, it uses `/tmp/test/syslog_perf/data` to gather test data during iterations and appends results to `./results.json`.

Inspect `./test_syslog_perf.sh` to see env vars which can be of use to overide defaults.

Note, because `/usr/bin/time` only provides measurements in centseconds (1/100 seconds), the number of messages generated needs to be large to produce measurable results.

The benchmark scripts do have `set -e` defined to abort if anything unexpected happens and leaves all data as is for the current benchmark run. Since it doesn't perform any recovery nor gracefully cleanup after, some background processes like a netcat listener (`nc`) or rsyslog process and stale PID file (`"$DATA_DIR/test_rsyslog_pid.txt"`) will need to be cleaned up manually.

## Test components and result gathering

The benchmark script is a wrapper around several test components and result gathering scripts.

### bash dummy syslog client

Implimented in `dummy_syslog_client.sh`. Makes use of the bash network socket file abstraction feature (i.e. `/dev/tcp/` and `/dev/udp`) and using background bash jobs to simulate mutliple clients sending a loop of test messages. Similar to the `util/test_syslog.sh` script, but avoids time system calls for every message to improve it's messaging rate.

### nc / BSD netcat dummy syslog server

Implimented in `dummy_syslog_server.sh`.

netcat dummy syslog listener limitations noticed:

- TCP connections with lots of dummy clients at once fail some connections?
- Similarly, UDP losses several packets with lots of dummy clients.
- UDP losses some messages with one client and no wait/delay between messages.
- `-q 1` for UDP mode is needed, otherwise client does not exit by itself.

### rsyslog syslog server

Compared using just the default main default queue and ruleset (`rsyslog_minimal_default_main_ruleset.conf`) versus a more complex and defined structure of rulesets and queues (`rsyslog_minimal_with_rulesets`) which mirrors what is done for the project.
