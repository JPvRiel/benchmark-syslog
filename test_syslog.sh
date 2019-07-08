#!/usr/bin/env bash

# Usage: ./test_syslog.sh --help"
# Note:
# - Depends on bash, date and bc
# - Some useful Linux utilities like logger and nmap are commented out and replaced with native bash to make this more friendly to MAC OSX devs ;-)

HELP_MSG='
Usage:
./test_syslog.sh -s|--servers=<comma seperated list> [-t|--tcp] [--tcp-port=<int>] [-u|--udp] [--udp-port=<int>] [-p|--parallel=<parallel instances>] [-c|--count=<messages>] [-w|--wait=<seconds between messages>] [--serial-per-host-and-protocol] [-v|--verbose]

-s=|--servers=<string> : server names or IPs seperated with commas and no spaces
-t|--tcp : Use TCP transport
--tcp-port=<int> : TCP port (default 601)
-u|--udp : Use UDP transport
--udp-port=<int> : UDP port (default 512)
-p|--parallel=<int> : parallel instances to run (simulate concurrent clients)
-c|--count=<int> : messages to send (simulate multiple messages per client)
-w|--wait=<float or int> : sleep in seconds between sending the next message
  * Default is 0 (fast as possible / no wait).
-r|--random-wait : randomise wait between 0 and --wait for each parallel instance
--serial_per_host_and_protocol : Serialise per host and protocol
  * Only target one server and protocol at a time
  * Makes traffic per syslog server ordered and easier for analysis
  * Message loop to a specific syslog server and protocol remains parallelised
  * Default is to send to all servers and protocols (TCP & UDP) concurrently
--severity=<int> : Set the numeric syslog severity level (0 to 7)
--facility=<int> : Set the numeric syslog facility level (0 to 23)
-v|--verbose : Verbose output
  * Shows last message per server, protocol and parallel instance
--debug : Print output for each message sent

E.g. send 1000 TCP and 1000 UDP messages to each host split into 10 parallel connections/streams
./test_syslog.sh -s=syslog.example.tld --tcp-port=514 -p=10 -c=100 -w=0.1
'

# Colour output with term colour escape codes
T_DEFAULT='\e[0m'
T_RED_BOLD='\e[1;31m'
T_BLUE='\e[0;34m'

function report_info() {
  echo -e "${T_BLUE}INFO:${T_DEFAULT} $*"
}

function report_error(){
  echo -e "${T_RED_BOLD}ERROR:${T_DEFAULT} $*" >&2
}

function random_wait() {
  if [ "$WAIT" != '0' ] && [ "$RANDOM_WAIT" == 'Y' ]; then
    WAIT="$(bc <<< "scale=9; $WAIT * $RANDOM / 32767")"
  fi
}

# Test syslog loop functions
function test_syslog_tcp() {
  random_wait
  if exec {tcp}> "/dev/tcp/$s/$TCP_PORT"; then
    tcp_errors=0
    m_5424=''
    for ((c=1; c<=COUNT; c++)); do
      t=$(date +"%Y-%m-%dT%H:%M:%S.%N%:z")  # ISO8601 timestamp for RFC5424 timestamp
      m_5424="<$PRIORITY>1 $t $h $pname $pid tcp-${p}-${c} [syslog_test parallel_instance=\"$p\" parallel_total=\"$PARALLEL\" count_current=\"$c\" count_total=\"$COUNT\" wait=\"$WAIT\"] sanity check TCP with RFC5424 for $s with parallel run $p of $PARALLEL and message $c of $COUNT"
      if ! echo "$m_5424" >&$tcp; then
        ((tcp_errors++))
      fi
      if [ "$DEBUG" == 'Y' ]; then
        printf '/dev/tcp/%s/%i: p=%i, c=%i, t=%s\n' "$s" "$TCP_PORT" "$p" "$c" "$t"
      fi
      if [ "$WAIT" != '0' ]; then
        sleep "$WAIT"
      fi
    done
    exec {tcp}>&-
    if [ $tcp_errors -gt 0 ]; then
      report_error "$tcp_errors TCP errors occured"
    fi
    if [ "$VERBOSE" == 'Y' ]; then
      echo "Final TCP message $((c - 1)) for instance $p sent to $s: '$m_5424'"
    fi
  else
    report_error "Unable to open TCP socket and connection to $s on port $TCP_PORT"
  fi
}

function test_syslog_udp() {
  random_wait
  if exec {udp}> "/dev/udp/$s/$UDP_PORT"; then
    udp_errors=0
    m_3164=''
    for ((c=1; c<=COUNT; c++)); do
      t=$(date +"%b %e %H:%M:%S")  # RF3164 timestamp
      m_3164="<$PRIORITY>$t $h ${pname}[${pid}]: sanity check UDP with RFC3164 for $s with parallel run $p of $PARALLEL and message $c of $COUNT with wait $WAIT"
      if ! echo "$m_3164" >&$udp; then
        ((udp_errors++))
      fi
      if [ "$DEBUG" == 'Y' ]; then
        printf '/dev/tcp/%s/%i: p=%i, c=%i, t=%s\n' "$s" "$UDP_PORT" "$p" "$c" "$t"
      fi
      sleep "$WAIT"
    done
    exec {udp}>&-
    if [ $udp_errors -gt 0 ]; then
      report_error "$udp_errors UDP errors occured"
    fi
    if [ "$VERBOSE" == 'Y' ]; then
      echo "Final UDP message $((c - 1)) for instance $p sent to $s: '$m_3164'"
    fi
  else
    report_error "Unable to open UDP socket for $s on port $UDP_PORT"
  fi
}

# Parse options
SERVERS=()
TCP='N'
TCP_PORT=601
UDP='N'
UDP_PORT=514
PARALLEL=1
COUNT=1
WAIT=0
RANDOM_WAIT='N'
SERIAL_PER_HOST_AND_PROTOCOL='N'
SEVERITY=6
FACILITY=1
VERBOSE='N'
for i in "$@"; do
  case $i in
    -s=*|--servers=*)
      IFS=',' read -r -d '' -a SERVERS <<< "${i#*=}"
      shift
      ;;
    -t|--tcp)
      TCP='Y'
      ;;
    --tcp-port=*)
      TCP_PORT="${i#*=}"
      shift # past argument=value
      ;;
    -u|--udp)
      UDP='Y'
      ;;
    --udp-port=*)
      UDP_PORT="${i#*=}"
      shift # past argument=value
      ;;
    -p=*|--parallel=*)
      PARALLEL="${i#*=}"
      shift # past argument=value
      ;;
    -c=*|--count=*)
      COUNT="${i#*=}"
      shift # past argument=value
      ;;
    -w=*|--wait=*)
      WAIT="${i#*=}"
      shift # past argument=value
      ;;
    -r|--random-wait)
      RANDOM_WAIT='Y'
      ;;
    --serial-per-host-and-protocol)
      SERIAL_PER_HOST_AND_PROTOCOL='Y'
      ;;
    --severity=*)
      SEVERITY="${i#*=}"
      ;;
    --facility=*)
      FACILITY="${i#*=}"
      ;;
    -v|--verbose)
      VERBOSE='Y'
      ;;
    --debug)
      DEBUG='Y'
      ;;
    -h|--help)
      echo "$HELP_MSG"
      exit 1
      ;;
    *) # unknown option
      report_error "'$i' is not a known option"
      echo "Try -h|--help for options"
      exit 1
    ;;
  esac
done
# Test both TCP and UDP by default if neither --tcp or --udp option was used
if ! [[ "$TCP" == 'Y' || "$UDP" == 'Y' ]]; then
  TCP='Y'
  UDP='Y'
fi
# Set default env
if [[ ${#SERVERS[@]} -eq 0 ]]; then
  report_info "No server name(s) supplied with -s=|--server=<comma seperated list>, so assuming localhost."
  SERVERS=('localhost')
fi
PRIORITY=$((FACILITY * 8 + SEVERITY))
# Attempt to use bash builtin for sleep
if [ "$WAIT" != '0' ]; then
  report_info "A wait between messages depends on the sleep command or shell builtin and this will add system load."
  export BASH_LOADABLES_PATH=$(pkg-config bash --variable=loadablesdir)
  if ! enable -f sleep sleep; then
    # check if sleep is less than a second and warn if not using builtin sleep
    if [ $(bc -l <<< "$s_delay < 1") -eq 1 ]; then
      report_error "Unable to load the bash sleep built in and the small $s_delay will peform poorly using the external execution of sleep at $(which sleep)"
    fi
  fi
fi

# Estimate execution time and number of messages produced
h=$(hostname)
pid=$$
pname=$(basename "$0")
protocols_enabled=0
for i in $TCP $UDP; do
  if [ "$i" == 'Y' ]; then
    ((protocols_enabled++))
  fi
done
if [ "$TCP" == 'Y' ]; then
  tcp_message_count_per_host=$(( PARALLEL * COUNT ))
else
  tcp_message_count_per_host=0
fi
tcp_message_count_per_protocol=$(( tcp_message_count_per_host * ${#SERVERS[@]} ))
if [ "$UDP" == 'Y' ]; then
  udp_message_count_per_host=$(( PARALLEL * COUNT ))
else
  udp_message_count_per_host=0
fi
udp_message_count_per_protocol=$(( udp_message_count_per_host * ${#SERVERS[@]} ))
report_info "Starting bash syslog sanity check script on host $h with pid $pid"
report_info "Parameters: PARALLEL=$PARALLEL, COUNT=$COUNT, WAIT=$WAIT, SERIAL_PER_HOST_AND_PROTOCOL=$SERIAL_PER_HOST_AND_PROTOCOL, TCP=$TCP, UDP=$UDP"
if [ "$SERIAL_PER_HOST_AND_PROTOCOL" == 'Y' ]; then
  wait_added=$(echo "scale=1; $WAIT * $COUNT * ${#SERVERS[@]} * $protocols_enabled" | bc)
else
  wait_added=$(echo "scale=1; $WAIT * $COUNT" | bc)
fi
report_info "Expected: TCP = $tcp_message_count_per_host x ${#SERVERS[@]} = $tcp_message_count_per_protocol, UDP = $udp_message_count_per_host x ${#SERVERS[@]} = $udp_message_count_per_protocol, and wait added = $wait_added (random=$RANDOM_WAIT)"
echo

t_start=$(date +"%Y-%m-%dT%H:%M:%S.%N")
for s in ${SERVERS[*]}; do
  report_info "server: $s"
  if [ "$TCP" == 'Y' ]; then
    # TCP test message
    report_info "proto: TCP"
    for ((p=1; p<=PARALLEL; p++)); do
      test_syslog_tcp &
    done
    if [ "$SERIAL_PER_HOST_AND_PROTOCOL" == 'Y' ]; then
      wait
    fi
  fi
  if [ "$UDP" == 'Y' ]; then
    # UDP test message
    report_info "proto: UDP"
    for ((p=1; p<=PARALLEL; p++)); do
      test_syslog_udp &
    done
    if [ "$SERIAL_PER_HOST_AND_PROTOCOL" == 'Y' ]; then
      wait
    fi
  fi
  echo
done
wait
# Calc end time
t_end=$(date +"%Y-%m-%dT%H:%M:%S.%N")
bc_t_delta_calc="$(date --date="$t_end" +%s.%N) - $(date --date="$t_start" +%s.%N)"
t_delta_s=$(bc <<< "$bc_t_delta_calc")
t_delta_s=$(printf '%.3f' "$t_delta_s")

# Final report
echo
report_info "Started at $(date --date="$t_start" +'%H:%M:%S'), completed at $(date --date "$t_end" +'%H:%M:%S'), with ${t_delta_s}s run time"
report_info "$tcp_message_count_per_protocol TCP and $udp_message_count_per_protocol UDP messages should be indexed in total ($tcp_message_count_per_host TCP and $udp_message_count_per_host UDP per host)"
report_info "ElasticSearch index query hint: 'hostname:$h AND app-name:test_syslog.sh AND procid:$pid'"
