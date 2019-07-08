# Syslog Performance Testing

## bash script to generate test messages

For generic test against any or multiple servers that accept plain TCP or UDP, see: `test_syslog.sh --help`.

Note:

- The final output provides an example query to use in elasticsearch to find events related to a test run.
- It's potentially useful as a reliability test against an already loaded syslog service.
- The use of the external call to `date` for each message limits it's applicability as a load generation script.

## Comparative test scripts

The `benchmark` folder has scripts to test baseline performance with netcat, bash and rsyslog configurations to compare overheads, etc. What follows is a brief summary. For more detail, see [benchmark/README.md].

### dummy syslog client and sever

Unlike `test_syslog.sh`, the scripts use environment variables (container friendly). The `dummy_syslog_clients.sh` generates messages more rapidly by only using `date` at the start and end of a pseudo-client's spool of messages. Still, due to being written in bash, the output performance isn't optimal.

There's intentional dummy output protocol choice of `none` which sets the output to /dev/null. So none of the messages generated get sent to the syslog server (100% failure rate of course). this allows measuring the overhead of starting and stopping the benchmark without receiving any messages.

While the rsyslog impstats module generates sufficient system metrics for rsyslog, the /usr/bin/time function was used to create an overall summary as complimentary information. Most notably, is was a fun exercise to compare rsyslog with a psudo-syslog server that simply directs netcat listener output to file (`dummy_syslog_server.sh`).

### python script to parse syslog json output

`benchmark/usr/local/bin/summarise_results_from_rsyslog_pstats_json_log.py` can parse, count and add summary stats over multiple metrics produced by impstats JSON file output.

`benchmark/usr/local/bin/flatten_and_compare_benchmark_results.py` further processes the data gathered from multiple benchmark runs, flatten nested JSON into a .csv format, and reports a few comparative stats between benchmarks.

## Performance impact of getting time with `TZ` unset

The `timeloop` folder contains a stand-alone benchmark used to inspect the impact of setting `TZ` and whether or not it impacted docker container system calls that obtained the time.

The results showed that failing to set `TZ` can negatively impact performance when C `stdlib.h`'s `locatime()` function is used. However, it was found rsyslog used C POSIX `sys/time.h`'s `gettimeofday()` instead which appears unaffected.

Note however, `TZ` was important for rsyslog correctly handling time zones (at lease so in prior versions of rsyslog placed in a container).

## Rsyslog options

### General queues

See: <https://github.com/rsyslog/rsyslog/blob/d70e3365c9e51d65364934ff8473437459cb8274/runtime/queue.c#L1559> for the source code that sets the main queue defaults which should also match defaults to ruleset queues. Note it's as follows:

| Option | rsyslog default |
| - | - |
| type | FixedArray |
| size | 50000 |
| dequeueBatchSize | 1024 |
| minDequeueBatchSize | 0 |
| minDequeueBatchSize.timeout | 1 |
| workerThreads | 1 |
| workerThreadMinimumMessages | `queue.size/queue.workerthreads` |

See the Dockerfile to note how the above defaults are increased.

### Input specific

#### `imptcp`

TODO

### Output specific

TODO

## Linux kernel tunables to consider

TODO

Linux kernel options related to rsyslog config

| Kernel option | Kernel description | RedHat default | Related rsyslog module and option(s) | Note |
| - | - | - | - | - |
| | | | imptcp SocketBacklog | |
| | | | imptcp ProcessOnPoller | |
| | | | imptcp/imtcp flowControl | |
| | | | imptcp/imtcp/imrelp KeepAlive | |

```console
/proc/sys/net/core/somaxconn
```

Other options

```console
/proc/sys/net/ipv4/tcp_max_syn_backlog
/proc/sys/net/core/rmem_max
```

Rsyslog related: TODO

```console
https://github.com/rsyslog/rsyslog/issues/81
http://rsyslog-users.1305293.n2.nabble.com/TCP-Keep-Alive-use-cases-td7590143.html
```

Kernel related: TODO

```console
https://vincent.bernat.ch/en/blog/2014-tcp-time-wait-state-linux
https://stackoverflow.com/questions/25503982/how-tcp-zero-window-can-be-detected-on-linux
https://eklitzke.org/how-tcp-sockets-work
http://veithen.io/2014/01/01/how-tcp-backlog-works-in-linux.html
https://perfchron.com/2015/12/26/investigating-linux-network-issues-with-netstat-and-nstat/
https://www.binarytides.com/linux-ss-command/
https://pracucci.com/linux-tcp-rto-min-max-and-tcp-retries2.html
https://access.redhat.com/solutions/893413
```

## References

- [Tutorial: sending impstats metrics to elasticsearch using rulesets and queues](https://www.rsyslog.com/tutorial-sending-impstats-metrics-to-elasticsearch-using-rulesets-and-queues)
- [rsyslog high performance config example](https://www.rsyslog.com/doc/v8-stable/examples/high_performance.html)
- [Performance Tuning&Tests for the Elasticsearch Output](https://www.rsyslog.com/performance-tuning-elasticsearch/)
- [iperf](https://github.com/esnet/iperf)
- [uperf github site](https://github.com/uperf/uperf) and [uperf.org](http://uperf.org/)