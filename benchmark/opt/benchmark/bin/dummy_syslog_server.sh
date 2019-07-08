#!/usr/bin/env bash
# A simple psudo syslog listener on UDP and TCP
set -e

# Syslog server and ports
SYSLOG_SERVER=${SYSLOG_SERVER:-'localhost'}
SYSLOG_UDP_PORT=${SYSLOG_UDP_PORT:-10514}
SYSLOG_TCP_PORT=${SYSLOG_TCP_PORT:-10601}

# Output
DATA_DIR=${DATA_DIR:-'/tmp/test/syslog_perf/data'}
if ! mkdir -p "$DATA_DIR"; then
  echo "ERROR: Unable to create '$DATA_DIR'. Aborting." >&2
  exit 1
fi
if ! [ -w "$DATA_DIR" ]; then
  echo "ERROR: Unable to write to '$DATA_DIR'. Aborting." >&2
  exit 1
fi

# Note, a double wait needed to fully and gracfull wait for singal propergation to take affect before exiting.
# - Without the double wait, the execution of the trap function call/commands seems to get missed out when measuring this script with /usr/bin/time
# - The kill command simply issues a singal and returns immediatly as well
# - So a second wait in the cleanup function is needed to ensure this calling script doesn't exit (and time stops measuring) before nc child processes have stopped.
# See: http://www.tldp.org/LDP/Bash-Beginners-Guide/html/sect_12_02.html
# "When Bash is waiting for an asynchronous command via the wait built-in, the reception of a signal for which a trap has been set will cause the wait built-in to return immediately with an exit status greater than 128, immediately after which the trap is executed."
function close_nc() {
  echo "[S] Closing netcat listeners on TCP (PID=$nc_tcp_pid) and UDP (PID=$nc_udp_pid)"
  kill -TERM "$nc_tcp_pid" "$nc_udp_pid"
  wait "$nc_tcp_pid" "$nc_udp_pid"
}
trap close_nc INT TERM

# Note:
# - $(jobs -p) with -p means "List only the process ID of the job’s process group leader" (nc)
# - $! would get the pid of wc process which is not what we want to kill after a signal trap
nc -d -l -k -u "$SYSLOG_SERVER" "$SYSLOG_UDP_PORT" > "$DATA_DIR/udp_dummy_nc.log" &
nc_udp_pid=$(jobs -p %1)
nc -d -l -k "$SYSLOG_SERVER" "$SYSLOG_TCP_PORT" > "$DATA_DIR/tcp_dummy_nc.log" &
nc_tcp_pid=$(jobs -p %2)
echo "[S] Dummy netcat UDP:$SYSLOG_UDP_PORT and TCP:$SYSLOG_TCP_PORT syslog listners started."
wait
#TODO, hand case where nc background process exit codes indicate failure
echo "[S] Dummy netcat syslog listeners stopped."
