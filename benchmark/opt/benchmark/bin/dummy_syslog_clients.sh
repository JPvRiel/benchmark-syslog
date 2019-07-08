#!/usr/bin/env bash
set -e

# Simple script to spool psudo syslog messages out via TCP or UDP

function test_syslog() {
  if exec {output}> "$OUTPUT_DEV"; then
    # Signal test start
    t_start=$(date --iso-8601=ns)
    syslog_header="<$syslog_priority>1 $t_start $hostname-$c $app_name $pid"
    # Reuse header and t_start in the message loop instead of doing date system calls per message
    for ((i = 1; i <= N_MESSAGES -1; i++)); do
      if [ "$S_DELAY" != '0' ]; then
         sleep "$S_DELAY"
      fi
      if ! { printf '%s %03i-%09i [syslog_perf_test_msg proto="%s" client_num="%03i" msg_num="%09i"] performance test message %i/%i.\n' "$syslog_header" $c $i "$syslog_proto" $c $i $i $N_MESSAGES; } >&$output; then
        ((failed_messages++))
      fi
    done
    # Final test message
    if [ "$S_DELAY" != '0' ]; then
      sleep "$S_DELAY"
    fi
    t_end=$(date --iso-8601=ns)
    syslog_header="<$syslog_priority>1 $t_end $hostname-$c $app_name $pid"
    if ! { printf '%s %03i-%09i [syslog_perf_test_msg proto="%s" client_num="%03i" msg_num="%09i"] performance test message %i/%i. Test complete. Test ran from to %s to %s.\n' "$syslog_header" $c $N_MESSAGES "$syslog_proto" $c $N_MESSAGES $N_MESSAGES $N_MESSAGES "$t_start" "$t_end"; } >&$output; then
      ((failed_messages++))
    fi
    exec {output}>&-
  else
    echo "[C] ERROR: Unable to open $OUTPUT_DEV" >&2
  fi
}

# Number of clients
N_CLIENTS=${N_CLIENTS:-1}
# Number of messages
N_MESSAGES=${N_MESSAGES:-10}
# Delay (note, sleep is external system call which adds)
S_DELAY=${S_DELAY:-0}
if [ "$S_DELAY" != '0' ]; then
  BASH_LOADABLES_PATH=$(pkg-config bash --variable=loadablesdir)
  export BASH_LOADABLES_PATH
  # try enable faster built-in for sleep
  if ! enable -f sleep sleep; then
    # check if sleep is less than a second and warn if not using builtin sleep
    if [ "$(bc -l <<< "$S_DELAY < 1")" -eq 1 ]; then
      echo "[C] ERROR: Unable to load the bash sleep built in and the small S_DELAY=$S_DELAY will peform poorly using the external execution of sleep at $(command -v sleep)" >&2
    fi
  fi
fi

# Syslog server and ports to target
SYSLOG_SERVER=${SYSLOG_SERVER:-'localhost'}
SYSLOG_UDP_PORT=${SYSLOG_UDP_PORT:-10514}
SYSLOG_TCP_PORT=${SYSLOG_TCP_PORT:-10601}

# Open a file descriptor depending on the choice of protocol
SYSLOG_PROTO=${SYSLOG_PROTO:-'udp'}
case "$SYSLOG_PROTO" in
  'tcp')
    syslog_proto='tcp'
    OUTPUT_DEV="/dev/tcp/$SYSLOG_SERVER/$SYSLOG_TCP_PORT"
    echo "[C] Set output to $OUTPUT_DEV"
    ;;
  'udp')
    syslog_proto='udp'
    OUTPUT_DEV="/dev/udp/$SYSLOG_SERVER/$SYSLOG_UDP_PORT"
    echo "[C] Set output to $OUTPUT_DEV"
    ;;
  'none')
    #output_cmd="cat > /dev/null"
    OUTPUT_DEV='/dev/null'
    echo "[C] Set output to $OUTPUT_DEV"
    ;;
  *)
    echo "[C] ERROR: SYSLOG_PROTO='$SYSLOG_PROTO'. Expects only 'none', 'tcp' or 'udp'" >&2
    exit 1
    ;;
esac

# Use info severity and user faciltiy
syslog_severity=6
syslog_facility=1
syslog_priority=$((syslog_facility * 8 + syslog_severity))
hostname=$(hostname)
app_name=$(basename "$0")
pid=$BASHPID
failed_messages=0

for ((c=1; c<=N_CLIENTS; c++)); do
  test_syslog &
done
echo "[C] Waiting for message spool test with $N_MESSAGES message(s) x $N_CLIENTS client(s) = $(( N_MESSAGES * N_CLIENTS )) to complete."
if [ "$S_DELAY" != '0' ]; then
  echo "[C] WARNING: Using sleep will add system call load. $(bc <<< "scale=1; $S_DELAY * $N_MESSAGES") delay added from ${S_DELAY}s x $N_MESSAGES message(s)." >&2
fi

wait
if [ $failed_messages -gt 0 ]; then
  echo "[C] $syslog_proto message send failures=$failed_messages" >&2
fi
echo '[C] Dummy bash client done!'