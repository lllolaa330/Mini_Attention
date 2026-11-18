#!/usr/bin/env python3
"""Rebuild two measured timelines from the archived first-frame schedules.

Run with /Users/jiaojiayi/miniconda3/bin/python3 plot_timelines.py.
No RTL or simulation is run. Only this figures directory is written.
"""
from pathlib import Path
import csv
import hashlib
import json
import platform

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import Patch, Rectangle
from matplotlib.lines import Line2D
from PIL import Image

HERE = Path(__file__).resolve().parent
ARCHIVE = HERE.parent
BENCH = ARCHIVE / 'benchmarks'
ORDER = ['before_os', 'after_os', 'before_ws', 'after_ws']
NAMES = {'before_os': 'OS · before', 'after_os': 'OS · after',
         'before_ws': 'WS · before', 'after_ws': 'WS · after'}
C = {'qk': '#2878B5', 'sm': '#5FADAD', 'pv': '#8662A5',
     'wait': '#DDE2E5', 'weights': '#D7A64A', 'clear': '#7D8790',
     'out': '#28313A', 'text': '#28313A', 'grid': '#E5E8EA'}
plt.rcParams.update({
    'font.family': 'DejaVu Sans', 'font.size': 10,
    'text.color': C['text'], 'axes.labelcolor': C['text'],
    'xtick.color': C['text'], 'ytick.color': C['text'],
    'axes.edgecolor': '#ADB6BC', 'axes.linewidth': .7,
    'figure.facecolor': 'white', 'axes.facecolor': 'white',
    'pdf.fonttype': 42, 'ps.fonttype': 42, 'svg.fonttype': 'none',
    'savefig.facecolor': 'white',
})


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def intervals(cycles):
    out = []
    for c in sorted(set(cycles)):
        if out and c == out[-1][1] + 1:
            out[-1][1] = c
        else:
            out.append([c, c])
    return out


def read_data():
    comparison = json.loads((BENCH / 'comparison.json').read_text())
    assert comparison['status'] == 'PASS'
    data = {'scope': 'Frame 0, all_zero; pre-edge sampled actions.',
            'cycle_convention': '1-based inclusive; stream origin=first input transfer; '
                                'resident origin=CLEAR_QK edge.',
            'source_sha256': {'benchmarks/comparison.json': sha(BENCH/'comparison.json')},
            'series': {}}
    for mode in ['resident', 'stream']:
        data['series'][mode] = {}
        for name in ORDER:
            folder = BENCH / name / mode
            path = folder / 'schedule.csv'
            rows = [{k: int(v, 16) if k == 'out_mask' else int(v)
                     for k, v in r.items()}
                    for r in csv.DictReader(path.open())]
            summary = json.loads((folder / 'summary.json').read_text())
            assert summary['status'] == 'PASS' and summary['bit_exact']
            f0 = summary['per_frame'][0]
            assert f0['case_name'] == 'all_zero'
            assert [r['relative_cycle'] for r in rows] == list(range(1, len(rows)+1))
            def selected(pred):
                return [r['relative_cycle'] for r in rows if pred(r)]
            event = {
                'clear': selected(lambda r: r['state'] in (1, 5)),
                'qk': selected(lambda r: r['state'] == 2 and r['array_step']),
                'sm': selected(lambda r: r['state'] in (3, 4)),
                'pv': selected(lambda r: r['state'] == 6 and r['array_step']),
                'wait': selected(lambda r: r['state'] == 10 or
                                 (r['state'] == 6 and not r['array_step'])),
                'shift_k': selected(lambda r: r['ws_shift_qk']),
                'shift_v': selected(lambda r: r['ws_shift_v']),
                'row_v': selected(lambda r: r['ws_row_load']),
                'out': selected(lambda r: r['out_fire']),
            }
            assert len(event['pv']) == (47 if name.endswith('ws') else 46)
            assert len(event['qk']) == len(event['pv'])
            assert len(event['out']) == 31
            assert sum(r['out_mask'].bit_count() for r in rows if r['out_fire']) == 256
            assert event['out'][0] == f0['first_output_latency']
            assert event['out'][-1] == f0['last_output_latency']
            assert event['out'] == list(range(event['out'][0], event['out'][-1]+1))
            version, flow = name.split('_')
            pair = comparison['per_case'][flow][mode][0]
            assert pair['first_output_latency'][version] == event['out'][0]
            assert pair['last_output_latency'][version] == event['out'][-1]
            series = {'intervals': {k: intervals(v) for k, v in event.items()},
                      'event_counts': {k: len(v) for k, v in event.items()},
                      'row_writes': [[r['relative_cycle'], r['ws_load_row']]
                                     for r in rows if r['ws_row_load']],
                      'first_output': event['out'][0], 'last_output': event['out'][-1],
                      'pv_enabled_steps': [[r['relative_cycle'], r['feed_step']]
                                           for r in rows if r['state']==6 and r['array_step']],
                      'input_transfers': [[r['relative_cycle'], r['input_frame'], r['input_word']]
                                          for r in rows if r['input_fire']]}
            assert [s for _, s in series['pv_enabled_steps']] == list(range(len(event['pv'])))
            if name == 'after_ws':
                assert [row for _, row in series['row_writes']] == list(range(16))
                series['row_writes_during_softmax'] = sum(t in event['sm'] for t,_ in series['row_writes'])
            data['series'][mode][name] = series
            for source in [path, folder/'summary.json']:
                data['source_sha256'][str(source.relative_to(ARCHIVE))] = sha(source)
    return data


def bars(ax, ranges, y, color, height=.38, edge='none'):
    ax.broken_barh([(a-.5, b-a+1) for a,b in ranges],
                   (y-height/2, height), facecolors=color, edgecolors=edge,
                   linewidth=.35, zorder=3)


def label_bar(ax, ranges, y, text, color='white', fontsize=10):
    if ranges:
        a,b=max(ranges,key=lambda r:r[1]-r[0])
        ax.text((a+b)/2,y,text,ha='center',va='center',color=color,
                fontsize=fontsize,zorder=5)


def prepare_axis(ax, xlim, ylim, ticks):
    ax.set_xlim(*xlim); ax.set_ylim(*ylim)
    ax.set_xticks(ticks); ax.set_yticks([])
    ax.grid(axis='x',color=C['grid'],linewidth=.6,zorder=0)
    ax.spines[['top','right','left']].set_visible(False)
    ax.tick_params(axis='x',length=3,pad=5)


def lane_label(ax, y, text, size=9.5, weight='normal'):
    ax.text(-.013,y,text,transform=ax.get_yaxis_transform(),ha='right',va='center',
            fontsize=size,fontweight=weight,clip_on=False)


def timeline_group(ax, s, name, y, mode):
    iv=s['intervals']
    lane_label(ax,y+.58,NAMES[name],11.3,'bold')
    lane_label(ax,y,'Compute')
    lane_label(ax,y-.7,'Weight writes')
    lane_label(ax,y-1.4,'Output')
    for kind in ['wait','clear','qk','sm','pv']:
        bars(ax,iv[kind],y,C[kind])
    if mode=='resident':
        label_bar(ax,iv['qk'],y,f"QK  {s['event_counts']['qk']} steps")
        label_bar(ax,iv['sm'],y,'Softmax',color=C['text'],fontsize=9.5)
        label_bar(ax,iv['pv'],y,f"PV  {s['event_counts']['pv']} steps")
    else:
        label_bar(ax,iv['qk'],y,'QK',fontsize=9.5)
        label_bar(ax,iv['sm'],y,'SM',color=C['text'],fontsize=9)
        if name.startswith('before'):
            label_bar(ax,iv['wait'],y,f"Wait for V  ({s['event_counts']['wait']} cycles)",color=C['text'])
            label_bar(ax,iv['pv'],y,f"PV · {s['event_counts']['pv']}",fontsize=9)
        else:
            # Count only the actual enabled cycles; the gray gaps are stalls.
            a=iv['pv'][0][0]; b=iv['pv'][-1][1]
            ax.text((a+b)/2,y+.42,
                    f"PV: {s['event_counts']['pv']} enabled steps + {s['event_counts']['wait']} wait cycles",
                    ha='center',va='center',fontsize=9.7,color=C['pv'])
            label_bar(ax,[iv['pv'][-1]],y,'PV tail',fontsize=9)

    for kind in ['shift_k','shift_v','row_v']:
        bars(ax,iv[kind],y-.7,C['weights'],height=.28)
    if not any(iv[k] for k in ['shift_k','shift_v','row_v']):
        ax.text(ax.get_xlim()[0]+2,y-.7,'—',color='#9AA3AA',va='center')
    if mode=='resident':
        label_bar(ax,iv['shift_k'],y-.7,'K shift',C['text'],9)
        label_bar(ax,iv['shift_v'],y-.7,'V shift',C['text'],9)
        label_bar(ax,iv['row_v'],y-.7,'V rows 0→15',C['text'],8.6)
    else:
        label_bar(ax,iv['shift_k'],y-.7,'K',C['text'],9)
        label_bar(ax,iv['shift_v'],y-.7,'V',C['text'],9)
        if s['row_writes']:
            first4=s['row_writes'][:4]
            ax.text(sum(t for t,_ in first4)/4,y-1.02,'rows 0–3',ha='center',va='center',fontsize=8.5)
            for t,row in s['row_writes'][4:]:
                ax.text(t,y-1.02,str(row),ha='center',va='center',fontsize=8.2)

    first,last=s['first_output'],s['last_output']
    bars(ax,iv['out'],y-1.4,C['out'],height=.12)
    ax.scatter([first,last],[y-1.4]*2,s=19,c=C['out'],zorder=6)
    ax.text((first+last)/2,y-1.69,f'{first}–{last}',ha='center',va='center',fontsize=10)
    ax.axhline(y-2.0,color=C['grid'],lw=.7)


def legend(fig,y):
    handles=[Patch(facecolor=C[k],label=v) for k,v in
             [('qk','QK enabled step'),('sm','Softmax incl. start'),
              ('pv','PV enabled step'),('wait','Wait for V'),
              ('weights','K / V weight write'),('clear','Array clear')]]
    handles.append(Line2D([],[],color=C['out'],marker='o',markersize=4,label='Output handshake'))
    fig.legend(handles=handles,loc='center',bbox_to_anchor=(.51,y),ncol=7,
               frameon=False,fontsize=9.5,handlelength=1.4,columnspacing=1.45)


def export(fig,stem):
    paths=[]
    for ext in ['png','pdf','svg']:
        path=HERE/f'{stem}.{ext}'
        fig.savefig(path,dpi=350,facecolor='white')
        paths.append(path)
    plt.close(fig)
    return paths


def resident_figure(data):
    fig=plt.figure(figsize=(16.8,8.8))
    fig.text(.04,.958,'On-chip-resident inputs: V row loading overlaps Softmax',
             fontsize=18,fontweight='bold')
    fig.text(.04,.917,'Q, K and V are preloaded. Last output: OS 113 → 113 cycles; WS 147 → 131 cycles (16 saved).',
             fontsize=11.4)
    legend(fig,.872)
    ax=fig.add_axes([.16,.205,.81,.60])
    prepare_axis(ax,(.5,154),(-.3,12.1),[1,16,32,48,64,80,96,112,128,144])
    for name,y in zip(ORDER,[11,8,5,2]):
        timeline_group(ax,data['series']['resident'][name],name,y,'resident')
    ax.set_xlabel('Clock cycle  (cycle 1 = CLEAR_QK edge)',labelpad=9,fontsize=11)
    # A quiet annotation outside bars makes the overlap explicit.
    ax.annotate('16 row writes during Softmax',xy=(72.5,1.3),xytext=(53,.2),
                ha='center',fontsize=9.7,color='#8F661A',
                arrowprops={'arrowstyle':'-','lw':.8,'color':'#8F661A'})
    fig.text(.04,.12,'Shown: frame 0, all_zero. Pre-edge actions; ranges and latency include both endpoint cycles. '
             'Dots mark first / last of 31 accepted output groups (256 FP16 values).',fontsize=9.5)
    fig.text(.04,.082,'The three other resident test cases take one extra Softmax cycle. Each WS GEMM includes its bottom-row writeback step; '
             '47 enabled array steps are not 47 fully occupied FMA cycles.',fontsize=9.5)
    fig.text(.04,.044,'Source: benchmarks/{before,after}_{os,ws}/resident/schedule.csv + comparison.json. '
             'Measured RTL simulation cycles; frequency, area and power are not evaluated.',fontsize=9.2,color='#5E6972')
    return export(fig,'timeline_resident')


def overview(ax,data):
    prepare_axis(ax,(.5,840),(.05,5.55),[1,256,512,768,833])
    reference=data['series']['stream']['before_ws']['input_transfers']
    assert [r[0] for r in reference]==list(range(1,834))
    input_ranges=[(1,256,'Q₀  1–256'),(257,512,'K₀  257–512'),
                  (513,768,'V₀  513–768'),(769,833,'Q₁ →')]
    for a,b,label in input_ranges:
        bars(ax,[[a,b]],4.95,'#E6EEF4',height=.43,edge='#A6B9C9')
        ax.text((a+b)/2,4.95,label,ha='center',va='center',fontsize=10)
    lane_label(ax,4.95,'FP16 input',10,'bold')
    for name,y in zip(ORDER,[3.8,2.8,1.8,.8]):
        s=data['series']['stream'][name];iv=s['intervals']
        lane_label(ax,y,NAMES[name],10)
        for kind in ['wait','clear','qk','sm','pv']:
            bars(ax,iv[kind],y,C[kind],height=.30)
        for kind in ['shift_k','shift_v','row_v']:
            bars(ax,iv[kind],y-.25,C['weights'],height=.12)
        bars(ax,iv['out'],y-.43,C['out'],height=.10)
    ax.add_patch(Rectangle((509.5,.15),330,4.2,fill=False,edgecolor='#ADB6BC',lw=.8,zorder=7))
    ax.text(516,4.35,'Expanded below',fontsize=9,color='#65717A')
    ax.set_xlabel('Clock cycle from first input transfer',labelpad=6,fontsize=10)


def stream_figure(data):
    fig=plt.figure(figsize=(16.8,12.4))
    fig.text(.04,.969,'Streaming inputs: PV advances while V is still arriving',fontsize=18,fontweight='bold')
    fig.text(.04,.941,'Last output: OS 816 → 785 cycles; WS 833 → 802 cycles. Both save 31 cycles; input frame interval remains 768 cycles.',
             fontsize=11.4)
    legend(fig,.908)
    fig.text(.04,.873,'A  Complete input and compute view',fontsize=12,fontweight='bold')
    top=fig.add_axes([.16,.681,.81,.175])
    overview(top,data)
    fig.text(.04,.620,'B  Detail: every enabled PV step and WS weight write',fontsize=12,fontweight='bold')
    ax=fig.add_axes([.16,.155,.81,.438])
    prepare_axis(ax,(509.5,840),(-.3,12.1),[512,560,608,656,704,752,800,832])
    for name,y in zip(ORDER,[11,8,5,2]):
        timeline_group(ax,data['series']['stream'][name],name,y,'stream')
    ax.axvline(768.5,color='#8E99A2',lw=.85,ls='--',zorder=2)
    ax.text(768.5,11.93,'V₀ complete | Q₁ starts 769',ha='center',va='center',fontsize=9.5,
            bbox={'facecolor':'white','edgecolor':'none','pad':1.5})
    ax.set_xlabel('Clock cycle  (cycle 1 = first Q₀ input transfer)',labelpad=8,fontsize=11)
    fig.text(.04,.092,'Shown: frame 0, all_zero; continuous input (1 FP16 / cycle), always-ready output. '
             'Thin purple cells are real enabled steps; gray cells are V waits, not computation.',fontsize=9.5)
    fig.text(.04,.062,'WS row-write labels identify V rows 0–15; the first five rows are written during Softmax. '
             'Output labels are first–last accepted groups (31 total). Q₁ is shown only through cycle 833.',fontsize=9.5)
    fig.text(.04,.032,'Source: benchmarks/{before,after}_{os,ws}/stream/schedule.csv + comparison.json. '
             'Pre-edge, 1-based inclusive cycles; all four benchmark cases pass bit-exact checks. No Fmax claim.',fontsize=9.2,color='#5E6972')
    return export(fig,'timeline_stream')


def main():
    data=read_data()
    (HERE/'plotted_data.json').write_text(json.dumps(data,indent=2)+'\n')
    outputs=resident_figure(data)+stream_figure(data)
    report={'status':'PASS','python':platform.python_version(),'matplotlib':matplotlib.__version__,
            'font':'DejaVu Sans','png_dpi_requested':350,'source_sha256':data['source_sha256'],
            'script_sha256':sha(Path(__file__)),'outputs':{}}
    for p in outputs:
        info={'sha256':sha(p),'bytes':p.stat().st_size}
        if p.suffix=='.png':
            with Image.open(p) as im:
                info.update(pixels=list(im.size),dpi=list(im.info['dpi']))
                assert all(abs(d-350)<.1 for d in im.info['dpi'])
        report['outputs'][p.name]=info
    (HERE/'figure_manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['outputs'],indent=2))


if __name__=='__main__':
    main()
