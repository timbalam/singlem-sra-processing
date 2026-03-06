#!/usr/bin/env python3

###############################################################################
#
#    Copyright (C) 2020 Ben Woodcroft
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
###############################################################################

__author__ = "Ben Woodcroft"
__copyright__ = "Copyright 2020"
__credits__ = ["Ben Woodcroft"]
__license__ = "GPL3"
__maintainer__ = "Ben Woodcroft"
__email__ = "benjwoodcroft near gmail.com"
__status__ = "Development"

import argparse
import logging
import sys
import os
import time
import extern
import itertools
import tempfile
import queue

sys.path = [os.path.join(os.path.dirname(os.path.realpath(__file__)),'..')] + sys.path

def iterable_chunks(iterable, n):
    '''Given an iterable, return it in chunks of size n. In the last chunk, the
    remaining space is replaced by None entries.
    '''
    args = [iter(iterable)] * n
    return itertools.zip_longest(*args, fillvalue=None)

if __name__ == '__main__':
    parent_parser = argparse.ArgumentParser()

    parent_parser.add_argument('--input-runlist', required=True, help='newline separated list of accessions to process')
    parent_parser.add_argument('--workflow-template', required=True, help='workflow template to use')
    parent_parser.add_argument('--sleep-interval', type=int, help='sleep this many seconds between submissions', default=60 * 5)
    parent_parser.add_argument('--min-running-pending-file', help='only submit when the number of jobs is below this (a number in a file)')
    parent_parser.add_argument('--batch-size', type=int, help='submit this many each time')
    parent_parser.add_argument('--batch-size-file', help='read from a file which is just a number - submit this many each time')
    parent_parser.add_argument('--blacklist', help='Ignore accessions that are in this file')
    parent_parser.add_argument('--whitelist', help='Only submit accessions that are in this file')
    
    parent_parser.add_argument('--debug', help='output debug information', action="store_true")
    #parent_parser.add_argument('--version', help='output version information and quit',  action='version', version=repeatm.__version__)
    parent_parser.add_argument('--quiet', help='only output errors', action="store_true")

    args = parent_parser.parse_args()

    # Setup logging
    if args.debug:
        loglevel = logging.DEBUG
    elif args.quiet:
        loglevel = logging.ERROR
    else:
        loglevel = logging.INFO
    logging.basicConfig(level=loglevel, format='%(asctime)s %(levelname)s: %(message)s', datefmt='%m/%d/%Y %I:%M:%S %p')

    with open(args.input_runlist) as f:
        entries = list([s.strip() for s in f.readlines()])
    logging.info(f"Found {len(entries)} accessions from input runlist")

    whitelist = []
    blacklist = []
    if args.whitelist:
        with open(args.whitelist) as f:
            whitelist = list([s.strip() for s in f.readlines()])
    if args.blacklist:
        with open(args.blacklist) as f:
            blacklist = list([s.strip() for s in f.readlines()])
    logging.info(f"Read {len(whitelist)} whitelist and {len(blacklist)} blacklist accessions")

    num_submitted = 0
    qu = queue.Queue()
    for e in entries:
        if args.whitelist is None or e['acc'] in whitelist:
            if args.blacklist is None or e['acc'] not in blacklist:
                qu.put(e)
    total_to_submit = qu.qsize()
    logging.info(f"Found {total_to_submit} accessions to submit after white and blacklist filtering")

    if args.batch_size:
        batch_size = args.batch_size
    elif args.batch_size_file:
        batch_size = 0
    else:
        raise Exception("Need batch size or batch size file")

    while not qu.empty():
        if args.min_running_pending_file:
            with open(args.min_running_pending_file) as f:
                min_running_pending = int(f.read().strip())
                while True:
                    try:
                        # Get workflows not pods because otherwise we don't get the full list
                        pods_output = extern.run("kubectl get workflows -n argo --no-headers")
                        running_pending = sum(1 for line in pods_output.splitlines()
                                              if len(line.split()) >= 3 and line.split()[1] in ('Running', 'Pending'))
                        logging.info(f"Running/Pending: {running_pending}")
                        break
                    except extern.ExternCalledProcessError as e:
                        logging.warning(f"Failed to get kubectl pod list. Retrying after pause. Error was {e}")
                        time.sleep(args.sleep_interval)
                        continue
                if running_pending >= min_running_pending:
                    logging.info(f"Found {running_pending} running/pending jobs, need min {min_running_pending} to finish before submitting more")
                    time.sleep(args.sleep_interval)
                    continue
        if args.batch_size_file:
            with open(args.batch_size_file) as f:
                prev = batch_size
                batch_size = int(f.read().strip())
                if prev != batch_size:
                    logging.info(f"Changing batch size to {batch_size} entries")
        chunk = []
        while not qu.empty() and len(chunk) < batch_size:
            chunk.append(qu.get())

        # Submit each with argo submit
        # Keep trying submission, in case of head node failure.
        for i, iterchunk in enumerate(iterable_chunks(chunk, 50)):
            iterchunk = [x for x in iterchunk if x is not None]
            
            with tempfile.NamedTemporaryFile(mode='w') as f:
                with open(args.workflow_template) as template_file:
                    template = template_file.read()

                first = True
                for acc in iterchunk:
                    if first:
                        first = False
                    else:
                        f.write("\n---\n")
                    lower_acc = acc.lower()
                    f.write(template.replace("{{workflow.parameters.SRA_accession_num}}", acc).replace('generateName: singlem-aws-', f'generateName: slow-{lower_acc}-'))
                f.flush()

                while True:
                    try:
                        template = args.workflow_template
                        os.makedirs("submissions", exist_ok=True)
                        extern.run(f"argo submit -n argo -o json {f.name} |jq > submissions/slow-{i}-`date +%Y%m%d-%I%M`.argo_submission.json")
                    except extern.ExternCalledProcessError as e:
                        logging.warning("Failed to argo submit. Retrying after pause. Error was {}".format(e))
                        time.sleep(args.sleep_interval)
                        continue

                    logging.info("Submitted")
                    break

        num_submitted += len(chunk)
        logging.info(f"Submitted {num_submitted} out of {total_to_submit} i.e. {round(float(num_submitted)/total_to_submit*100)}%")

        if num_submitted < total_to_submit:
            logging.info("sleeping ..")
            time.sleep(args.sleep_interval)

    logging.info("Finished all submissions")
