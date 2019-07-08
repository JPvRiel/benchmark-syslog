#!/usr/bin/env python3
# rsyslog produces raw stats in a log file in either @CEE or plain JSON.
# E.g.
# `Mon Jul  1 15:31:19 2019: { "name": "imudp(*:10514)", "origin": "imudp", "submitted": 100000 }`
# `Mon Jul  1 15:31:19 2019: { "name": "resource-usage", "origin": "impstats", "utime": 607857, "stime": 630538, "maxrss": 4504, "minflt": 532, "majflt": 0, "inblock": 0, "oublock": 50768, "nvcsw": 139802, "nivcsw": 16, "openfiles": 14 }``

import argparse
import re
import io
import sys
import warnings
import datetime
import json
import collections
import statistics


def datetimes_to_iso(o):
  """
  convert datetime.datetime instances into string representations
  handle some types of collections by recursively walking keys and/or values in a dict or list
  helps avoid json.dumps() 'TypeError: keys must be str, int, float, bool or None, not datetime.datetime'
  """
  if isinstance(o, datetime.datetime):
    return o.isoformat()
  if isinstance(o, list):
    return [datetimes_to_iso(i) for i in o]
  if isinstance(o, dict):
    return {datetimes_to_iso(k): datetimes_to_iso(v) for (k, v) in o.items()}
  if isinstance(o, tuple):
    return tuple(datetimes_to_iso(i) for i in o)
  return o

def prune_none_and_empty(d):
  """
  Remove keys that have either null values, empty strings or empty arrays
  See: https://stackoverflow.com/a/27974027/5472   
  """
  if isinstance(d, list):
    return [v for v in (prune_none_and_empty(v) for v in d) if v]
  if isinstance(d, dict):
    return {k: v for k, v in ((k, prune_none_and_empty(v)) for k, v in d.items()) if v}
  return d

parser = argparse.ArgumentParser(description='Process results from rsyslog impstats in JSON format.')
parser.add_argument('-i', '--input-rsyslog-pstats-file', default='-', help='defaults to \'-\' which is <stdout>')
parser.add_argument('-o', '--output-summary-json-file', default='-', help='defaults to \'-\' which is <stdout>')
parser.add_argument('-a', '--aggregate-stats', action='store_true',  help='show overall statistics grouped per metric in the \'agg_stats\' key')
parser.add_argument('-v', '--show-values', action='store_true',  help='list the metric values within the \'agg_stats\' key')
parser.add_argument('-0', '--show-zero-values', action='store_true', help='Show zero or null values within the \'agg_stats\' key')
parser.add_argument('-s', '--original-stats', action='store_true', help='Output a \'original_stats\' key that includes the original stats. Always shows zero values.')
parser.add_argument('-n', '--no-flatten', action='store_true', help='Group stats per timestamp and don\'t flatten output')
parser.epilog='Summarised output is added at the end. The default is to print a timestamp for every stat (flattend) format.'
args = parser.parse_args()

# input
if args.input_rsyslog_pstats_file == '-':
  input_stream = sys.stdin
else:
  input_stream = open(args.input_rsyslog_pstats_file, 'r')

# output
if args.output_summary_json_file == '-':
  output_stream = sys.stdout
else:
  output_stream = open(args.output_summary_json_file, 'w')

METRICS_WHERE_SUM_HAS_MEANING = {
  # queue
  'msgs.received',
  'called.recvmsg',
  'discarded.nf',
  'discarded.full',
  'full',
  # inputs
  # imptcp & imudp
  'submitted',
  # imptcp
  'sessions.opened',
  'sessions.closed',
  'sessions.openfailed',
  'bytes.received',
  'bytes.decompressed',
  # imdup worker thread
  'called.recvmmsg',
  'called.recvmsg',
  'msgs.received',
  # rsyslog action metrics
  'processed',
  'failed',
  'suspended',
  'resumed',  
  # rsyslog resource usage related to http://man7.org/linux/man-pages/man2/getrusage.2.html
  'utime',
  'stime',
  'minflt',
  'majflt',
  'inblock',
  'oublock',
  'nvcsw',
  'nivcsw'
}
# some metric names are generated dynamically and can only determined later
dynamic_metrics_where_sum_has_meaning = set()
JSON_ARRAY_OBJECT_START = '{['
JSON_ARRAY_OBJECT_END = ']}'
# Note:
# - The date header of the messages, e.g. `Mon Jul  1 15:31:19 2019:` is a fixed length of 24 char before `:`.
# - @cee format can optionally be in use
PATTERN = '^(?P<str_timestamp>.{24}): (?:@cee: )?(?P<json_stat>\{.*\})$'
re_extract = re.compile(PATTERN)

# Collections to process, aggregate and report results
stats_ordered = collections.OrderedDict()
results = {}

# Note, used regex in case other content is in the file, e.g. shared syslog file.
line_count = 0
for line in input_stream:
  line_count += 1
  matched = re_extract.match(line)
  # skip if match failed
  if not (matched and 'str_timestamp' in matched.groupdict() and 'json_stat' in matched.groupdict()):
    warnings.warn('Skipped line {} of {} because timestamp and/or JSON pattern did not match.'.format(line_count, input_stream.name))
    continue
  # parse
  stat_timestamp = datetime.datetime.strptime(matched['str_timestamp'], '%a %b %d %H:%M:%S %Y')
  json_stat = json.loads(matched['json_stat'])
  if stat_timestamp not in stats_ordered:
    stats_ordered[stat_timestamp] = []
    stats_ordered[stat_timestamp].append(json_stat)
  else:
    stats_ordered[stat_timestamp].append(json_stat)

if not stats_ordered:
  raise ValueError('Unable to match any rsyslog pstats in JSON or CEE format from {}'.format(input_stream.name))

# Process timestamps for each stat
if args.original_stats:
  if args.no_flatten:
    original_stats = stats_ordered
  else:
    original_stats = []
    for k_timestamp, v_stats in stats_ordered.items():
      #for stat in v_stats:
      #  stat['timestamp'] = k_timestamp
      #  stats.append(stat)
      # Create new dict in order cooerse timestamp as the first key
      for stat in v_stats:
        current_stat = {'timestamp': k_timestamp}
        current_stat.update(stat)
        original_stats.append(current_stat)
  results['original_stats'] = original_stats

# Re-organise and group values per stat name, origin and set of metrics in preperation for overall stats calculations later
grouped_stats = {}
for (k_timestamp, v_stats) in stats_ordered.items():
  for stat in v_stats:
    if stat['name'] not in grouped_stats:
      grouped_stats[stat['name']] = {'origin': stat['origin'], 'metrics': {}}
    for k, v in stat.items():
      # only sum when values are numerics
      if isinstance(v, (int, float)):
        if k not in grouped_stats[stat['name']]['metrics']:
          grouped_stats[stat['name']]['metrics'][k] = {'values': {k_timestamp: v}}
        else:
          grouped_stats[stat['name']]['metrics'][k]['values'].update({k_timestamp: v})
      # process dynstats related items which groups items into values and flatten it into the way other stats are structured
      elif (stat['origin'] == 'dynstats.bucket' or stat['origin'] == 'dynstats.bucket') and k == 'values':
        assert isinstance(v, dict), 'dynstats.bucket object imported from JSON has unexpected structure'
        for dk, dv in v.items():
          if dk not in grouped_stats[stat['name']]['metrics']:
            dynamic_metrics_where_sum_has_meaning.add(dk)
            grouped_stats[stat['name']]['metrics'][dk] = {'values': {k_timestamp: dv}}
          else:
            grouped_stats[stat['name']]['metrics'][dk]['values'].update({k_timestamp: dv})

# Calculate stats from grouped metric values
agg_stats = grouped_stats
for (k_gstat, v_gstat) in grouped_stats.items():
  for (k_metric, v_metric) in v_gstat['metrics'].items():
    values_non_zero = prune_none_and_empty(v_metric['values'])
    agg_stats[k_gstat]['metrics'][k_metric].update({'count': len(v_metric['values'])})
    agg_stats[k_gstat]['metrics'][k_metric].update({'count_non_zero': len(values_non_zero)})
    agg_stats[k_gstat]['metrics'][k_metric].update({'min': min(v_metric['values'].values())})
    agg_stats[k_gstat]['metrics'][k_metric].update({'max': max(v_metric['values'].values())})
    agg_stats[k_gstat]['metrics'][k_metric].update({'mean': statistics.mean(v_metric['values'].values())})
    if args.show_zero_values:
      mean_non_zero, t_min, t_max, t_delta_s = None, None, None, None
    if values_non_zero:
      mean_non_zero = statistics.mean(values_non_zero.values())
      # min / max timestamp values assume values dict is still ordered by time
      t_min = list(values_non_zero.keys())[0]
      t_max = list(values_non_zero.keys())[-1]
      t_delta_s = (t_max - t_min).seconds
      agg_stats[k_gstat]['metrics'][k_metric].update({'mean_non_zero': mean_non_zero})
      agg_stats[k_gstat]['metrics'][k_metric].update({'timestamp_non_zero_min': t_min})
      agg_stats[k_gstat]['metrics'][k_metric].update({'timestamp_non_zero_max': t_max})
      agg_stats[k_gstat]['metrics'][k_metric].update({'time_delta_seconds_non_zero': t_delta_s})
    # summations for stats where summation makes sense
    if k_metric in METRICS_WHERE_SUM_HAS_MEANING or k_metric in dynamic_metrics_where_sum_has_meaning:
      agg_stats[k_gstat]['metrics'][k_metric].update({'sum': sum(v_metric['values'].values())})
    if args.show_values:
      if not args.show_zero_values:
        agg_stats[k_gstat]['metrics'][k_metric].update({'values': values_non_zero})
    else:
      del(agg_stats[k_gstat]['metrics'][k_metric]['values'])

if args.aggregate_stats:
  results['agg_stats'] = agg_stats
  t_start = list(stats_ordered.keys())[0]
  t_end = list(stats_ordered.keys())[-1]
  t_runtime_s = (t_end - t_start).seconds
  results['timestamp_start'] = t_start
  results['timestamp_end'] = t_end
  results['runtime_seconds'] = t_runtime_s

# wrap results in a container so it can be combined with outher json sources
results_with_prefix = {'rsyslog_pstats': results}

if output_stream.name == '<stdout>':
  output_stream.write(json.dumps(datetimes_to_iso(results_with_prefix), indent=2))
  output_stream.write('\n')
else:
  output_stream.write(json.dumps(datetimes_to_iso(results_with_prefix), separators=(',', ':')))

# Cleanup
if input_stream.name != '<stdin>':
  input_stream.close()
if output_stream.name != '<stdout>':
  output_stream.close()