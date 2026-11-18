"""Render the actual PV enable/hold events and spatial MAC occupancy from cycles.csv."""
import csv
import json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
from matplotlib.ticker import MultipleLocator, FuncFormatter

HERE=Path(__file__).resolve().parent
DATA=HERE/'matched'
OUT=HERE/'figures'
OUT.mkdir(exist_ok=True)
meta=json.loads((DATA/'comparison.json').read_text())['measurements']
with (DATA/'cycles.csv').open() as f:
    allrows=list(csv.DictReader(f))
plt.rcParams.update({'font.family':'DejaVu Sans','axes.spines.top':False,
                     'axes.spines.right':False,'svg.fonttype':'none','pdf.fonttype':42,
                     'axes.labelcolor':'#203340','xtick.color':'#3c4a51','ytick.color':'#3c4a51',
                     'font.size':11})
fig=plt.figure(figsize=(12.0,6.6),facecolor='white',layout='constrained')
ax,bx=fig.subplots(2,1,gridspec_kw={'height_ratios':[1.0,1.08]})
active='#247968';vwait='#d8a651';owait='#9d5c85'
left=1;right=252
for i,m in enumerate(meta):
    rows=[r for r in allrows if r['version']==m['version'] and r['mode']==m['mode']]
    rows=[r for r in rows if int(r['PV_T'])>=1]
    assert len(rows)==m['pv_first_to_last']
    colors=[active if int(r['pv_step']) else (vwait if not int(r['v_ready']) else owait) for r in rows]
    start=0
    for j in range(1,len(colors)+1):
        if j==len(colors) or colors[j]!=colors[start]:
            ax.barh(3-i,j-start,left=start+0.5,height=.55,color=colors[start],edgecolor='none',zorder=3)
            start=j
    ax.text(len(rows)+2.5,3-i,f"{m['pv_idle']} idle",va='center',fontsize=10)
ax.set_yticks(range(3,-1,-1),['Scalar V · ready','Scalar V · backpressure','Column V · ready','Column V · backpressure'])
ax.set_xlim(.5,270);ax.set_ylim(-.62,3.58);ax.set_xlabel('Cycle from the first PV array step (cycle 1)')
ax.xaxis.set_major_locator(MultipleLocator(25))
ax.xaxis.set_major_formatter(FuncFormatter(lambda x,pos: str(int(x)) if x>=1 else ''))
ax.grid(axis='x',color='#e4e8eb',linewidth=.6)
ax.set_title('A   PV execution and stalls',loc='left',weight='bold',pad=24,fontsize=14)
ax.legend(handles=[Patch(color=active,label='PV step'),Patch(color=vwait,label='Waiting for V'),
                   Patch(color=owait,label='Output buffer full')],loc='lower right',bbox_to_anchor=(1,1),
                   frameon=False,ncol=3,fontsize=10,borderaxespad=0)
for ver,color,label in [('before','#68798e','Scalar V'),('after',active,'Column V')]:
    rs=[r for r in allrows if r['version']==ver and r['mode']=='ready']
    xx=[int(r['T']) for r in rs]
    yy=[int(r['qk_pe'])+int(r['pv_pe']) for r in rs]
    # Each sample is the count of successfully accepted MACs on that edge.
    bx.stairs(yy,[x-.5 for x in xx]+[xx[-1]+.5], color=color, linewidth=1.4,label=label)
bx.set_xlim(.5,271.5);bx.set_ylim(0,256)
bx.set_yticks([0,64,128,192,256]);bx.xaxis.set_major_locator(MultipleLocator(25))
bx.set_title('B   Number of PEs accepting a MAC on each cycle, ready output',loc='left',weight='bold',fontsize=14,pad=12)
bx.set_xlabel('Cycle from the first QK MAC (cycle 1)');bx.set_ylabel('Active PEs (of 256)')
bx.legend(frameon=False,ncol=2,loc='upper right')
bx.grid(axis='y',color='#e4e8eb',linewidth=.6)
for axis in [ax,bx]:
    axis.tick_params(axis='both',length=3)
    for side in ['bottom','left']:axis.spines[side].set_color('#c2cbd0')
for ext in ['png','svg','pdf']:
    fig.savefig(OUT/f'pv_waveforms.{ext}',dpi=350,facecolor='white')
