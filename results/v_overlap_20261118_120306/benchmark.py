#!/usr/bin/env python3
"""Replay either frozen RTL version in stream and preloaded-memory modes."""
import argparse
import csv
from datetime import datetime
from hashlib import sha256
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BENCH = HERE/'tb_overlap_bench.sv'


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n')


def execute(args, cwd, log, timeout):
    args = list(map(str,args))
    print('+', ' '.join(args), flush=True)
    with log.open('w') as out:
        out.write('COMMAND: '+repr(args)+'\n')
        out.flush()
        subprocess.run(args, cwd=cwd, stdout=out, stderr=subprocess.STDOUT,
                       timeout=timeout, check=True)


def build(variant, flow, cases, dest, manifest, timeout):
    rtl = HERE/variant/'rtl'
    if not rtl.is_dir():
        raise ValueError(f'Missing frozen source directory {rtl}')
    files = []
    hashes = {str(BENCH.relative_to(ROOT)):digest(BENCH), str((rtl/'files.f').relative_to(ROOT)):digest(rtl/'files.f')}
    for entry in (rtl/'files.f').read_text().splitlines():
        if entry.startswith('+incdir+'):
            path = ROOT/entry[8:]
            files.append('+incdir+'+str(path))
            for header in path.glob('*.vi'):
                hashes[str(header.relative_to(ROOT))]=digest(header)
        elif entry.strip():
            path = rtl/Path(entry).name if entry.startswith('rtl/') else ROOT/entry
            files.append(str(path))
            hashes[str(path.relative_to(ROOT))]=digest(path)
    if variant=='before':
        for name, reference in json.loads((HERE/'before_sha256.json').read_text()).items():
            if digest(HERE/'before'/name)!=reference:
                raise ValueError(f'Before snapshot changed: {name}')
    manifest.update(compiled_source_sha256=hashes, rom_sha256=digest(rtl/'exp_fp16.hex'))
    save(dest/'manifest.json',manifest)
    (dest/'compile.f').write_text('\n'.join(files)+'\n')
    execute(['iverilog','-V'], dest, dest/'version.log',timeout)
    cmd = ['iverilog','-g2012','-s','tb_overlap_bench', f'-Ptb_overlap_bench.CASES={len(cases)}',
           f'-Ptb_overlap_bench.USE_WS={int(flow=="ws")}', '-o','bench.vvp','-f','compile.f']
    if variant=='after':
        cmd.append('-DNEW_V_SCHEDULER')
    execute(cmd+[BENCH], dest,dest/'compile.log',timeout)


def verify_mode(directory, cases, mode):
    sys.path.insert(0,str(ROOT))
    from model.attention import errors
    timing = [{k:int(v) for k,v in entry.items()} for entry in csv.DictReader((directory/'timing.csv').open())]
    if len(timing)!=len(cases) or 'BENCH PASS' not in (directory/'simulation.log').read_text():
        raise ValueError('Missing completed frames')
    words = [int(v,16) for v in (directory/'actual.hex').read_text().split()]
    if words!=[w for case in cases for w in case['expected']]:
        raise ValueError('Attention output differs from the SoftFloat fixture')
    for index,(frame,case) in enumerate(zip(timing,cases)):
        if frame['frame']!=index or (frame['output_beats'], frame['output_words'])!=(31,256):
            raise ValueError(f'Capture count mismatch for frame {index}')
        frame['case_name']=case['name']
        frame['rmse'],frame['max_abs_error']=errors(words[index*256:(index+1)*256],case['float64_reference'])
        if frame['rmse']>0.06 or frame['max_abs_error']>0.20: raise ValueError('Accuracy threshold exceeded')
        expected_ii=timing[index]['origin']-timing[index-1]['origin'] if mode=='stream' and index else -1
        if frame['input_ii']!=expected_ii: raise ValueError('Incorrect initiation interval')
        if frame['input_ii']==-1: frame['input_ii']=None
    schedule=list(csv.DictReader((directory/'schedule.csv').open()))
    row0=timing[0]
    beats=[int(s['relative_cycle']) for s in schedule if int(s['out_fire'])]
    if (list(range(1,row0['last_output_latency']+1))!=[int(s['relative_cycle']) for s in schedule] or
        len(beats)!=31 or (beats[0],beats[-1])!=(row0['first_output_latency'],row0['last_output_latency'])):
        raise ValueError('Per-edge schedule does not agree with frame 0 summary')
    if mode=='stream' and int(schedule[0]['input_word'])!=0: raise ValueError('Missing streaming origin')
    if mode=='resident' and int(schedule[0]['state'])!=1: raise ValueError('Missing resident CLEAR_QK origin')
    return {'mode':mode, 'status':'PASS','frames':len(cases),'output_beats':31*len(cases),
            'outputs':len(words),'bit_exact':True,'per_frame':timing,
            'schedule_scope':'Frame 0; pre-edge values, first measured edge is relative cycle 1.',
            'actual_sha256':digest(directory/'actual.hex')}


def compare(base):
    output={}
    for flow in ('os','ws'):
        output[flow]={}
        for mode in ('stream','resident'):
            metrics={}
            for label in ('before','after'):
                path=base/(label+'_'+flow)/mode/'summary.json'
                s=json.loads(path.read_text())
                if s['status']!='PASS': raise ValueError(f'Invalid summary: {path}')
                metrics[label]=s
            if metrics['before']['actual_sha256']!=metrics['after']['actual_sha256']:
                raise ValueError('Before and after output words differ')
            fields=('first_output_latency','last_output_latency','input_ii')
            rows=[]
            for a,b in zip(metrics['before']['per_frame'],metrics['after']['per_frame']):
                if a['case_name']!=b['case_name']: raise ValueError('Differing frame order')
                row={'case':a['case_name']}
                for field in fields:
                    row[field]={'before':a[field],'after':b[field],
                                'cycles_saved':a[field]-b[field] if a[field] is not None else None}
                rows.append(row)
            output[flow][mode]=rows
    save(base/'comparison.json',{'status':'PASS','units':'inclusive cycles from first input transfer (stream) '
                                 'or CLEAR_QK edge (resident); input_ii uses start-to-start difference',
                                 'first_frame_schedule':'<version>_<flow>/<mode>/schedule.csv','per_case':output})
    print('Comparison:',base/'comparison.json')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant',choices=['before','after'])
    parser.add_argument('--flow',choices=['os','ws'])
    parser.add_argument('--compare',action='store_true')
    parser.add_argument('--root-out',type=Path,default=HERE/'benchmarks')
    parser.add_argument('--timeout',type=int,default=900)
    args=parser.parse_args()
    base=args.root_out.resolve()
    if args.compare:
        compare(base)
        return
    if not args.variant or not args.flow: parser.error('Specify --variant and --flow or --compare')
    cases=json.loads((HERE/'cases.json').read_text())
    dest=base/(args.variant+'_'+args.flow)
    dest.mkdir(parents=True,exist_ok=False)
    manifest={'status':'RUNNING','started':datetime.now().astimezone().isoformat(),
              'variant':args.variant,'flow':args.flow,'argv':sys.argv,
              'fixture':'cases.json','fixture_sha256':digest(HERE/'cases.json'),
              'seed':20261117,'fixture_source_case_ids':[c['source_case'] for c in cases],
              'script_sha256':digest(Path(__file__))}
    save(dest/'manifest.json',manifest)
    try:
        build(args.variant,args.flow,cases,dest,manifest,args.timeout)
        for resident,mode in enumerate(('stream','resident')):
            directory=dest/mode
            directory.mkdir()
            for name,key in [('input','words'),('expected','expected')]:
                (directory/(name+'.hex')).write_text(''.join(f'{w:04x}\n' for c in cases for w in c[key]))
            shutil.copyfile(HERE/args.variant/'rtl'/'exp_fp16.hex',directory/'exp_fp16.hex')
            execute(['vvp', dest/'bench.vvp', f'+RESIDENT={resident}'],directory,directory/'simulation.log',args.timeout)
            summary=verify_mode(directory,cases,mode)
            save(directory/'summary.json',summary)
            print(mode,summary['per_frame'][0],flush=True)
        manifest['status']='PASS'
    except Exception as exc:
        manifest.update(status='FAIL',error=repr(exc))
        raise
    finally:
        manifest['finished']=datetime.now().astimezone().isoformat()
        save(dest/'manifest.json',manifest)


if __name__=='__main__':
    main()
