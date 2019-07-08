#!/usr/bin/env bash
set -e

# Check for needed commands/binaries
for exe in 'nc' 'bc' 'jq' 'pgrep' 'kill' 'time' 'rsyslogd'; do
  if ! hash "$exe"; then
    echo "ERROR: $exe command not found." >&2
    exit 1
  fi
done

# Note unbuffer depends on expect, but a python anaconda environment can break expected dependancies
# See: https://anaconda.org/Eumetsat/expect

# time format string to output JSON
# reference: https://gist.github.com/vadimkantorov/016326dfce61ddf6f00210440dcaa2c9
TIME_JSON_FORMAT='{"exit_code": %x, "time_user_seconds": %U, "time_system_seconds": %S, "time_wall_clock_seconds": %e, "rss_max_kbytes": %M, "rss_avg_kbytes": %t, "page_faults_major": %F, "page_faults_minor": %R, "io_inputs": %I, "io_outputs": %O, "context_switches_voluntary": %w, "context_switches_involuntary": %c, "cpu_percentage": "%P", "signals_received": %k}'
JQ_TIME_FILTER_PART='{time_user_seconds: .time_user_seconds, time_system_seconds: .time_system_seconds, time_wall_clock_seconds: .time_wall_clock_seconds ,context_switches_voluntary: .context_switches_voluntary, rss_max_kbytes: .rss_max_kbytes, page_faults_major: .page_faults_major, page_faults_minor: .page_faults_minor, io_inputs: .io_inputs, io_outputs: .io_outputs}'
JQ_RSYSLOG_PSTATS_DISPLAY_FILTER='{timestamp_start: .rsyslog_pstats.timestamp_start, timestamp_end: .rsyslog_pstats.timestamp_end, runtime_seconds: .rsyslog_pstats.runtime_seconds, agg_stats: {"resource-usage": {metrics: {utime: {sum: .rsyslog_pstats.agg_stats."resource-usage".metrics.utime.sum, mean: .rsyslog_pstats.agg_stats."resource-usage".metrics.utime.mean}, stime: {sum: .rsyslog_pstats.agg_stats."resource-usage".metrics.stime.sum, mean: .rsyslog_pstats.agg_stats."resource-usage".metrics.stime.mean}, maxrss: {mean: .rsyslog_pstats.agg_stats."resource-usage".metrics.maxrss.mean, min: .rsyslog_pstats.agg_stats."resource-usage".metrics.maxrss.min, max: .rsyslog_pstats.agg_stats."resource-usage".metrics.maxrss.max}}}}}'

# Benchmark choices
n_platform_threads_available=$(nproc)
N_CLIENTS=${N_CLIENTS:-$(( n_platform_threads_available / 2 ))}
N_MESSAGES=${N_MESSAGES:-100000}
S_DELAY=${S_DELAY:-0}
N_REPITITIONS=${N_REPITITIONS:-3}
BENCH_DUMMY_NC=${BENCH_DUMMY_NC:-'Y'}
BENCH_RSYSLOG=${BENCH_RSYSLOG:-'Y'}
SHOW_JSON_SUMMARY='N'

# Directories in use
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
RSYSLOG_CONF_DIR=${RSYSLOG_CONF_DIR:-'./opt/rsyslog/etc'}
DATA_DIR=${DATA_DIR:-'/tmp/test/syslog_perf/data'}
mkdir -p "$DATA_DIR"
RESULT_FILE=${RESULT_FILE:-'./results.ndjson'}

# Export env vars for sub-scripts called
export DATA_DIR N_CLIENTS N_MESSAGES S_DELAY

# Clear old/previous result files (might be dangling from interuppted or failed benchmarks)

function clean_data() {
  rm -f "$DATA_DIR"/*.json
  rm -f "$DATA_DIR"/*.log
}

function bench_dummy() {
  if [[ -z "$proto" ]]; then
    echo "[T] ERROR: a variable was not assinged before calling bench_dummy()." >&2
    exit 1
  fi
  for ((r = 1; r <= N_REPITITIONS; r++)); do
    # Cleanup prior run
    clean_data
    echo -e "\n[T] ## dummy with protocol '$proto' for repitition $r/$N_REPITITIONS ##"
    time_stat_file="$DATA_DIR/${proto}_dummy_netcat_server.time.json"
    # time server and output results as json
    /usr/bin/time --quiet -f "$TIME_JSON_FORMAT" -o "$time_stat_file" "$SCRIPT_DIR/dummy_syslog_server.sh" &
    sleep 1
    # Don't kill the time process, as it seems to exit and report stats before the script has finished cleanly exiting!
    time_child_pid=$(pgrep -P $!)
    timestamp_client_start="$(date --iso-8601=s)"
    SYSLOG_PROTO="$proto" "$SCRIPT_DIR/dummy_syslog_clients.sh"
    timestamp_client_end="$(date --iso-8601=s)"
    sleep 1
    kill -TERM "$time_child_pid"
    wait
    n_messages_generated=$(( N_CLIENTS * N_MESSAGES ))
    echo "[T] $proto client messages generated=$n_messages_generated"
    if [ "$proto" == 'udp' ] || [ "$proto" == 'tcp' ]; then
      n_messages_recieved=$(grep -c 'performance test message' "$DATA_DIR/${proto}_dummy_nc.log")
      echo "[T] $proto server messages recieve success=$n_messages_recieved"
      echo "[T] $proto server messages recieve failed=$((n_messages_generated - n_messages_recieved))"
    elif [ "$proto" == 'none' ]; then
      n_messages_recieved=0
    fi
    echo "[T] Process time's JSONified output and enrich results with benchmark metadata"
    if [[ "$SHOW_JSON_SUMMARY" == 'Y' ]]; then
      jq_expression_short="{total_messages_generated: $n_messages_generated, total_messages_recieved: $n_messages_recieved, time_info: $JQ_TIME_FILTER_PART}"
      jq "$jq_expression_short" "$time_stat_file"
    fi
    jq_expression_long="{test_info: {timestamp_client_start: \"$timestamp_client_start\", timestamp_client_end: \"$timestamp_client_end\", test: \"dummy server\", config_file: null, option: null, repitition: $r, repititions_total: $N_REPITITIONS, protocol: \"$proto\", clients: $N_CLIENTS, messages_per_client: $N_MESSAGES, total_messages_generated: $n_messages_generated, total_messages_recieved: $n_messages_recieved}, time_info: $JQ_TIME_FILTER_PART}"
    jq --compact-output "$jq_expression_long" "$time_stat_file" >> "$RESULT_FILE"
  done
}

function bench_rsyslog() {
  if [[ -z "$proto" || -z "$RSYSLOG_CONF_DIR" || -z "$conf_file" ]]; then
    echo "[T] ERROR: a variable was not assinged before calling bench_rsyslog()." >&2
    exit 1
  fi
  clean_data
  rsyslog_pid_file="$DATA_DIR/test_rsyslog_pid.txt"
  for ((r = 1; r <= N_REPITITIONS; r++)); do
    rsyslog_pstats_log_file="$DATA_DIR/rsyslog_pstats.log"
    rsyslog_pstats_agg_json_file="$DATA_DIR/rsyslog_pstats_agg_result.json"
    # clear previous files if present
    clean_data
    echo -e "\n[T] ## rsyslog baseline config '$conf_file' with protocol '$proto' for repitition $r/$N_REPITITIONS ##"  
    time_stat_file="$DATA_DIR/${proto}_minimal_rsyslog_server.time.json"
    if [ -f "$rsyslog_pid_file" ]; then
      echo "[T] ERROR: $rsyslog_pid_file exits and had $(cat "$rsyslog_pid_file"). rsyslogd is still running or the test script didn't exit cleanly. Abortinig."
      exit 1
    fi
    if rsyslogd -N1 -f "$RSYSLOG_CONF_DIR/$conf_file" &> /dev/null; then
      /usr/bin/time --quiet -f "$TIME_JSON_FORMAT" -o "$time_stat_file" rsyslogd -f "$RSYSLOG_CONF_DIR/$conf_file" -n -C -i "$rsyslog_pid_file" &
      time_child_pid=$(pgrep -P $!)
    else
      echo "[T] ERROR: rsyslog config check failed. Aborting." >&2
      rsyslogd -N1 -f "$RSYSLOG_CONF_DIR/$conf_file"
      exit
    fi
    echo "[T] rsyslog started"
    sleep 1
    timestamp_client_start="$(date --iso-8601=s)"
    SYSLOG_PROTO="$proto" "$SCRIPT_DIR/dummy_syslog_clients.sh"
    timestamp_client_end="$(date --iso-8601=s)"
    sleep 1
    kill -TERM "$(cat "$rsyslog_pid_file")"
    wait
    echo "[T] rsyslog exited (PID=$time_child_pid)"
    n_messages_generated=$(( N_CLIENTS * N_MESSAGES ))
    echo "[T] $proto client messages generated=$n_messages_generated"
    if [ "$proto" == 'udp' ] || [ "$proto" == 'tcp' ]; then
      n_messages_recieved=$(grep -c 'performance test message' "$DATA_DIR/rsyslog.log")
      echo "[T] $proto server messages recieve success=$n_messages_recieved"
      echo "[T] $proto server messages recieve failed=$((n_messages_generated - n_messages_recieved))"
    elif [ "$proto" == 'none' ]; then
      n_messages_recieved=0
    fi
    echo "[T] Process time's JSONified output and enrich results with benchmark metadata."
    if [[ "$SHOW_JSON_SUMMARY" == 'Y' ]]; then
      jq_expression_short="{total_messages_generated: $n_messages_generated, total_messages_recieved: $n_messages_recieved, time_info: $JQ_TIME_FILTER_PART}"
      jq "$jq_expression_short" "$time_stat_file"
    fi
    jq_expression_long="{test_info: {timestamp_client_start: \"$timestamp_client_start\", timestamp_client_end: \"$timestamp_client_end\", test: \"rsyslog server\", config_file: \"$conf_file\", option: null, repitition: $r, repititions_total: $N_REPITITIONS, protocol: \"$proto\", clients: $N_CLIENTS, messages_per_client: $N_MESSAGES, total_messages_generated: $n_messages_generated, total_messages_recieved: $n_messages_recieved}, time_info: $JQ_TIME_FILTER_PART}"
    jq --compact-output "$jq_expression_long" "$time_stat_file" > "$DATA_DIR/result.json"
    echo "[T] Aggregated and add summary rsyslog pstats metrics to results showing cpu times (microseconds) and resident memory use (kb)"
    python3 "$SCRIPT_DIR/summarise_results_from_rsyslog_pstats_json_log.py" -a -i "$rsyslog_pstats_log_file" -o "$rsyslog_pstats_agg_json_file"
    if [[ "$SHOW_JSON_SUMMARY" == 'Y' ]]; then
      jq "$JQ_RSYSLOG_PSTATS_DISPLAY_FILTER" "$rsyslog_pstats_agg_json_file"
    fi
    jq --compact-output -s '.[0] * .[1]' "$DATA_DIR/result.json" "$rsyslog_pstats_agg_json_file" >> "$RESULT_FILE"
  done
}


# dummy netcat server testing
if [ "$BENCH_DUMMY_NC" == 'Y' ]; then
  for proto in 'none' 'tcp' 'udp'; do
    echo -e "\n[T] ### dummy with protocol '$proto' ###"
    bench_dummy
  done
fi

# rsyslog server testing
if [ "$BENCH_RSYSLOG" == 'Y' ]; then
  
  # baseline input protocol
  conf_file='rsyslog_minimal_with_rulesets.conf'
  for proto in 'none' 'tcp' 'udp'; do
    echo -e "\n[T] ### rsyslog baseline protocols using '$conf_file' with protocol '$proto' ###"
    bench_rsyslog
  done

  # baseline default main Q vs multiple ruleset using tcp
  proto='tcp'
  for conf_file in 'rsyslog_minimal_default_main_ruleset.conf' 'rsyslog_minimal_with_rulesets.conf'; do
    echo -e "\n[T] ### rsyslog baseline main Q vs rulesets using '$conf_file' with protocol '$proto' ###"
    bench_rsyslog
  done

  # options TODO
  for o in 'udp input threads' 'udp batch size' 'udp buffer' 'tcp input threads' 'tcp socket backlog' 'tcp keepalive' 'queue threads' 'queue batch size'; do
    echo -e "\n[T] ## rsyslog benchmakr option '$o' using '$conf_file' protocol '$proto' ##"  
    echo "[T] TODO option $o"
  done

fi

echo -e "\n[T] ### Post-process results ###\n"
"$SCRIPT_DIR/flatten_and_compare_benchmark_results.py"
echo "TODO"
echo
