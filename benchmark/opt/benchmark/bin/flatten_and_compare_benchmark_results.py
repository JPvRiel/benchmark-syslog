#!/usr/bin/env python3
#%%
'''
Process the results NDJSON file and compare benchmark runs
'''
import argparse
import os
import json
from pandas.io.json import json_normalize

if __name__ == '__main__':
  parser = argparse.ArgumentParser(description='Process the results NDJSON file and compare benchmark runs.')
  parser.add_argument('-i', '--input-results-file', default='./results.ndjson', help='defaults to \'./results.ndjson\', but also looks for \'./test/syslog_perf/results.ndjson\'')
  parser.add_argument('-c', '--output-csv-file', default='./results.csv', help='defaults to \'./results.csv\'')
  '''
  There is a global argparse conflict. See: 
  - https://stackoverflow.com/a/47587545/5472444
  - https://stackoverflow.com/questions/48796169/how-to-fix-ipykernel-launcher-py-error-unrecognized-arguments-in-jupyter
  - https://stackoverflow.com/questions/36007990/handling-argparse-conflicts
  Fixed "ipykernel_launcher.py: error: unrecognized arguments: -f" error when defined as global
  '''
  args = parser.parse_args(args=[])

input_results_file = None
if (os.path.exists(args.input_results_file) and os.path.isfile(args.input_results_file)):
  input_results_file = args.input_results_file
else:
  # might be a test / interactive run in juypiter so try a relative path
  input_results_file_alternate = './test/syslog_perf/results.ndjson'
  if os.path.exists(input_results_file_alternate) and  os.path.isfile(input_results_file_alternate):
    input_results_file = input_results_file_alternate
  else:
    raise ValueError('Unable to locate input file. Use --input-results-file to specify it\'s location.')

#%%
'''
Parse NDJSON input file into a list
'''

all_results = []

with open(input_results_file, 'r') as input_file:
  for line in input_file:
    all_results.append(json.loads(line))

#%%
'''
Select and filter JSON paths of interest in preperation for normalising / flattening the JSON
'''

all_results_flattened = json_normalize(
  all_results
)
all_results_flattened.to_csv(args.output_csv_file)

#%%
'''
Average out accross benchmark instances / repetitions.

For resource usage stats:

- take the biggest max values.
- take the smallest min values.
- average the means.

For message counts:

- Find the average, best and worst message failure rates.
- Find the average, best and worst message/event per second rates (EPS).
  - True EPS message per second stats will depend on discarding partial 'buckets'.
  - A partial bucket is a 'boundary' between a 0 value and another neighboring non-zero values.

Use pandas to group and aggregate the stats accross the repetitions.
'''

# TODO