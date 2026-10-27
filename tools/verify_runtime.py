# Copyright 2026 Кислов Роман Сергеевич
# SPDX-License-Identifier: Apache-2.0

"""Controlled macOS run: process counters, independent netstat, synthetic traffic.
Run after launching gscaller with --diagnostics build/verification/display-aligned.jsonl.
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--reference-pid', help='Optional PID of a running reference monitor')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
out = root / 'build' / 'verification'
out.mkdir(parents=True, exist_ok=True)
stop = threading.Event()


def net_trace():
    with (out / 'netstat.jsonl').open('w') as f:
        while not stop.is_set():
            result = subprocess.run(['netstat', '-ibn'], capture_output=True, text=True, check=True)
            values = []
            for line in result.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 10 and parts[2].startswith('<Link#'):
                    # The optional MAC address adds one field to physical interfaces.
                    values.append({'interface': parts[0], 'received': int(parts[-5]), 'sent': int(parts[-2])})
            f.write(json.dumps({'at': datetime.datetime.now().astimezone().isoformat(), 'interfaces': values})+'\n')
            f.flush()
            stop.wait(2)


def phase(name, duration, transfer=False):
    pid = subprocess.check_output(['pgrep', '-x', 'gscaller'], text=True).strip()
    handles=[]
    targets = [('gscaller', pid)]
    if args.reference_pid:
        targets.append(('scaler', args.reference_pid))
    for label, target in targets:
        f=(out/(name+'-'+label+'.jsonl')).open('w')
        p=subprocess.Popen([str(root/'build/process_probe'), target,str(duration),'5'],stdout=f)
        handles.append((p,f))
    if transfer:
        time.sleep(5)
        results=[]
        for mode, command in [
            ('download', ['curl','-sS','--fail','--max-time','40','--limit-rate','1M','-o','/dev/null','-w','%{size_download} %{size_upload} %{time_total}', 'https://speed.cloudflare.com/__down?bytes=8388608']),
            ('upload', ['curl','-sS','--fail','--max-time','20','--limit-rate','256K','-o','/dev/null','-w','%{size_download} %{size_upload} %{time_total}','--data-binary','@'+str(out/'payload.bin'),'https://speed.cloudflare.com/__up'])]:
            result=subprocess.run(command,capture_output=True,text=True)
            results.append({'mode':mode,'returncode':result.returncode,'result':result.stdout,'error':result.stderr,'at':datetime.datetime.now().astimezone().isoformat()})
            print(mode,results[-1],flush=True)
        (out/'transfers.json').write_text(json.dumps(results,indent=2))
    for p,f in handles:
        p.wait();f.close()
    print(name+' completed',flush=True)

(out/'payload.bin').write_bytes(bytes(1024*1024))
thread=threading.Thread(target=net_trace)
thread.start()
try:
    phase('idle-final',60)
    phase('traffic-final',75,True)
finally:
    stop.set();thread.join()
