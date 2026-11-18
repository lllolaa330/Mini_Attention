"""Render a two-frame OS array schedule. Run python3 draw_timeline.py in any directory."""
import csv
import json
from html import escape
from pathlib import Path
import subprocess

out = Path(__file__).resolve().parent
frame_file = json.loads((out / 'frames.json').read_text())
frames = [frame_file['frames'][i]['events'] for i in (2, 3)]
base = frames[0]['QK'][0]
with (out / 'cycles.csv').open() as f:
    states = {int(r['cycle']): r for r in csv.DictReader(f)}

def rel(span):
    return [k-base for k in span]

a, b = [{key: rel(span) for key, span in frame.items()} for frame in frames]
for f in (a,b):
    assert f['QK'][1]-f['QK'][0]+1 == 46
    assert f['PV'][0]-f['QK'][0] == 36
assert b['QK'][0] == 85
retire = a['out'][1]
assert [states[base+j]['state'] for j in range(retire,retire+4)] == ['DRAIN','LOAD','CLEAR','COMPUTE']
assert int(states[base+retire]['output_last']) and int(states[base+retire]['output_fire'])

# Same relative stage latencies as in the measured ready-sink frame.
# Each PE and its matching edge lane need 16 steps per wave.
next_start = a['PV'][0]+16
model = [a, {key: [v+next_start for v in span] for key,span in a.items()
             if key in ('QK','PV','out')}]
overlap = (model[1]['QK'][0], model[0]['PV'][1])
assert overlap == (52,81)

width,height=1220,675
left,right=165,1195
xmin,xmax=-90,171
scale=(right-left)/(xmax-xmin)
def x(c): return left+(c-xmin)*scale
ink='#222F39'
sub='#526372'
line='#E1E6E8'
stage={'QK':'#276A9C','PV':'#C56738','prob_valid':'#C5E3D7','out':'#DBE5F0'}
svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
     '<style>text{font-family:"Source Han Sans CN","PingFang SC","Noto Sans CJK SC","Hiragino Sans GB",sans-serif}</style>']
def rect(x0,y,w,h,fill,stroke='none',sw=1):
    svg.append(f'<rect x="{x0:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"/>')
def rule(x1,y1,x2,y2,color=line,sw=1,dash=''):
    svg.append(f'<line x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" stroke="{color}" stroke-width="{sw}" stroke-dasharray="{dash}"/>')
def label(x0,y,text,sz=15,color=ink,anchor='start',weight=400):
    svg.append(f'<text x="{x0:.2f}" y="{y:.2f}" font-size="{sz}" font-weight="{weight}" text-anchor="{anchor}" fill="{color}">{escape(str(text))}</text>')
def band(span,y,fill,text,color=ink,fontsize=14,border=None):
    lo,hi=span
    rect(x(lo),y-12,(hi-lo+1)*scale,24,fill, border or 'white',1)
    label((x(lo)+x(hi+1))/2,y+4.7,text,fontsize,color,'middle',600)
def title(y,heading,note):
    label(25,y,heading,21,ink,weight=680)
    label(right,y,note,15,sub,'end')
def grid(ytop,ybottom,ticks):
    for c in ticks:
        rule(x(c), ytop, x(c), ybottom, '#8899A4' if c==0 else line, 1.5 if c==0 else 1, '' if c==0 else '3 4')
        label(x(c), ybottom+19, str(c).replace('-','−'),13,sub,'middle')
    rule(left,ybottom,right,ybottom,'#AAB5BD')
def stagebar(n,stage_id,y,span):
    fg='white' if stage_id in ('QK','PV') else ink
    if stage_id=='prob_valid':
        text=f'F{n+2}'
    else: text=f'F{n+2}  {span[0]}–{span[1]}'
    band(span,y,stage[stage_id],text,fg)
def row(y,name):
    label(left-11,y+5,name,16,ink,'end')
def bracket(c0,c1,y,text):
    l,r=x(c0),x(c1)
    rule(l,y,r,y,'#8B4D2D',1.5)
    for e in (l,r):rule(e,y,e,y+6,'#8B4D2D',1.5)
    label((l+r)/2,y-5,text,14,'#7E401F','middle',600)

rect(0,0,width,height,'white')
label(25,37,'连续两帧如何共用一个 OS 阵列',28,weight=700)
label(25,64,f'F2、F3 为连续输入的第 3、4 帧。两图共用周期轴，t = 0 对齐 F2 首个 QKᵀ 乘加（仿真第 {base} 拍）。',16,sub)
rule(25,80,right,80)
title(112,'当前 RTL  ·  波形实测','输入每帧 48 次握手  /  相邻帧的首个 QKᵀ 间隔 85 拍')
ticks=[-80,-60,-40,-20,0,20,40,60,80,100,120,140,160]
grid(128,300,ticks)
row(145,'输入握手')
for fid,f in enumerate((a,b)):
    for key,fill in (('Q','#D1E4F0'),('K','#BACDDF'),('V','#9CB6CB')):
        band(f[key],145,fill,f'F{fid+2}·{key}',fontsize=13)
during_stall = range(frames[0]['V'][1]+1, frames[1]['Q'][0])
assert len(during_stall)==37 and all(states[t]['in_ready']=='0' and states[t]['input_pending']=='1' for t in during_stall)
band((during_stall.start-base,during_stall.stop-base-1),145,'#FAF0E8','in_ready = 0 · 37 拍',color='#7E401F',fontsize=12)
for key,name,y in (('QK','阵列  QKᵀ',177),('prob_valid','Softmax  P 行返回',209),('PV','阵列  PV',241),('out','输出握手',273)):
    row(y,name)
    for fid,f in enumerate((a,b)):stagebar(fid,key,y,f[key])
label(25,351,'两帧之间',15,ink,weight=700)
label(124,351,f't = {retire}  F2 末组输出握手     →     {retire+1}  LOAD     →     {retire+2}  CLEAR     →     {retire+3}  F3 启动 QKᵀ',16,sub)
rule(25,372,right,372)
title(405,'跨帧调度  ·  阵列与 Softmax 独立仿真','保持每帧 QKᵀ 到 PV 的 36 拍启动距离  /  启动间隔 52 拍')
grid(439,582,ticks)
rect(x(overlap[0]),449,x(overlap[1]+1)-x(overlap[0]),71,'#FCECDC')
bracket(overlap[0],overlap[1]+1,444,'跨帧重叠 30 拍')
for key,name,y in (('QK','阵列  QKᵀ',466),('PV','阵列  PV',501),('out','取出结果',536)):
    row(y,name)
    for fid,f in enumerate(model):stagebar(fid,key,y,f[key])
row(569,'单个 PE[0,0]')
for fid,f in enumerate(model):
    for key in ('QK','PV'):
        start=f[key][0]
        band((start,start+15),569,stage[key],f'F{fid+2}·{key}','white',13)
label(25,637,'t 为相对时钟周期，条内起止拍均计入。下图输入已在片上，结果到达即采样。两帧共用同一组 PE 和 Softmax，顶层帧缓存及背压控制待实现。',15,sub)
svg.append('</svg>')
p=out/'two_frames.svg'
p.write_text('\n'.join(svg)+'\n')
for ext,args in [('pdf',[]),('png',['--zoom','2'])]:
    subprocess.run(['rsvg-convert',*args,'--format',ext,'--output',str(p.with_suffix('.'+ext)),str(p)],check=True)
