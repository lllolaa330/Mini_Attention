#!/usr/bin/env python3
"""Measure baseline/current with the same always-valid source and ready sink."""
import argparse,csv,datetime,hashlib,json,shutil,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def dump(p,v): p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n')
def prepare():
    if (HERE/'fixtures.json').exists(): return
    sys.path.insert(0,str(ROOT))
    from model.vectors import make_cases
    from model.attention import bit_model,reference
    cases=make_cases(seed=20261117,random_count=8)
    assert len(cases)==25
    expected=[bit_model(c['words']) for c in cases]
    (HERE/'input.hex').write_text(''.join(f'{x:04x}\n' for c in cases for x in c['words']))
    (HERE/'expected.hex').write_text(''.join(f'{x:04x}\n' for row in expected for x in row))
    dump(HERE/'cases.json',[dict(c,expected=e,float64_reference=reference(c['words'])) for c,e in zip(cases,expected)])
    dump(HERE/'fixtures.json',{'seed':20261117,'directed':17,'random':8,'frames':len(cases),'input_sha256':sha(HERE/'input.hex'),'expected_sha256':sha(HERE/'expected.hex'),'cases_sha256':sha(HERE/'cases.json'),'model_sha256':{str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'model').glob('*')) if p.is_file()}})

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--variant',choices=['baseline','current'],default='baseline')
    p.add_argument('--dataflow',choices=['os','ws'],default='os')
    p.add_argument('--prepare',action='store_true')
    p.add_argument('--outdir',type=Path)
    p.add_argument('--timeout',type=int,default=900)
    args=p.parse_args(); prepare()
    if args.prepare:
        print('Prepared shared fixtures:',HERE/'fixtures.json'); return
    now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    run=(args.outdir or HERE/(args.variant+'_'+args.dataflow+'_'+now.strftime('%Y%m%d_%H%M%S'))).resolve()
    run.mkdir(parents=True,exist_ok=False)
    snapshot=json.loads((HERE/'snapshot.json').read_text())
    if args.variant=='baseline':
        for path,digest in snapshot['snapshot_sources_sha256'].items():
            assert sha(HERE/path)==digest, 'Changed snapshot: '+path
        for path,digest in snapshot['dependencies_sha256'].items():
            assert sha(ROOT/path)==digest, 'Changed baseline dependency: '+path
    fixtures=json.loads((HERE/'fixtures.json').read_text())
    assert sha(HERE/'input.hex')==fixtures['input_sha256']
    assert sha(HERE/'expected.hex')==fixtures['expected_sha256']
    for name in ('input.hex','expected.hex'): shutil.copyfile(HERE/name,run/name)
    rtl=HERE/'rtl_snapshot' if args.variant=='baseline' else ROOT/'rtl'
    shutil.copyfile(rtl/'exp_fp16.hex',run/'exp_fp16.hex')
    lines=[]; source_hashes={}
    for line in (rtl/'files.f').read_text().splitlines():
        if not line.strip(): continue
        if line.startswith('+incdir+'):
            lines.append('+incdir+'+str(ROOT/line[len('+incdir+'):]))
        else:
            source=(rtl/Path(line).name) if line.startswith('rtl/') else ROOT/line
            lines.append(str(source)); source_hashes[str(source.relative_to(ROOT))]=sha(source)
    (run/'compile.f').write_text('\n'.join(lines)+'\n')
    bench=HERE/('tb_stream.sv' if args.variant=='baseline' else 'tb_stream_wide.sv')
    source_hashes[str(bench.relative_to(ROOT))]=sha(bench)
    manifest={'status':'RUNNING','time':now.isoformat(),'variant':args.variant,'dataflow':args.dataflow,'output_format':'scalar_row_major' if args.variant=='baseline' else 'diagonal_16lane','command':sys.argv,'fixtures':fixtures,'compiled_source_sha256':source_hashes,'baseline_top_sha256':snapshot['sha256']}
    dump(run/'manifest.json',manifest)
    def cmd(argv,log):
        print('+',' '.join(map(str,argv)),flush=True)
        with (run/log).open('w') as out:
            out.write('COMMAND: '+repr(list(map(str,argv)))+'\n'); out.flush()
            subprocess.run(list(map(str,argv)),cwd=run,stdout=out,stderr=subprocess.STDOUT,timeout=args.timeout,check=True)
    try:
        cmd(['iverilog','-V'],'tool_version.log')
        cmd(['iverilog','-g2012','-s','tb_stream',f'-Ptb_stream.CASES={fixtures["frames"]}',f'-Ptb_stream.USE_WS={int(args.dataflow=="ws")}','-o',run/'tb_stream.vvp','-f',run/'compile.f',bench],'compile.log')
        cmd(['vvp',run/'tb_stream.vvp'],'simulation.log')
        assert 'STREAM PASS' in (run/'simulation.log').read_text()
        assert (run/'actual.hex').read_bytes()==(run/'expected.hex').read_bytes()
        frames=[{k:int(v) for k,v in row.items()} for row in csv.DictReader((run/'timing.csv').open())]
        intervals=[f['input_ii'] for f in frames[1:]]
        out_intervals=[frames[i]['first_output']-frames[i-1]['first_output'] for i in range(1,len(frames))]
        summary={'frames':len(frames),'outputs':len(frames)*256,'bit_exact':True,'latency_min':min(f['latency'] for f in frames),'latency_max':max(f['latency'] for f in frames),'input_ii_min':min(intervals),'input_ii_max':max(intervals),'input_ii_mean':sum(intervals)/len(intervals),'first_output_ii_min':min(out_intervals),'first_output_ii_max':max(out_intervals),'first_output_ii_mean':sum(out_intervals)/len(out_intervals),'mean_useful_fma_occupancy':8192/(256*(sum(intervals)/len(intervals))),'timing':frames}
        dump(run/'summary.json',summary); manifest['status']='PASS'
        print('STREAM PASS', {k:v for k,v in summary.items() if k!='timing'},run)
    except Exception as e:
        manifest.update(status='FAIL',error=repr(e)); raise
    finally: dump(run/'manifest.json',manifest)

if __name__=='__main__': main()
