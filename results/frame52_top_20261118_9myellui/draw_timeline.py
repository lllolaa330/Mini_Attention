"""Draw both top-level timelines from clock edges sampled by compare_trace.py."""
import sys
import json
import subprocess
from pathlib import Path
from html import escape

dest=Path(sys.argv[1]).resolve()
data=json.loads((dest/'comparison.json').read_text())
width,height=1190,753
left,right=156,1164
xmin,xmax=-90,170
def x(c): return left+(c-xmin)*(right-left)/(xmax-xmin)
ink='#243441'; sub='#516474'; line='#DCE4E9'
color={'QK':'#256D99','PV':'#AF552A','P':'#C7E3DB','out':'#D9E6EE','Q':'#D6E9F3','K':'#B9D5E5','V':'#97BDD1'}
svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
     '<style>text{font-family:"Source Han Sans CN","PingFang SC","Noto Sans CJK SC","Hiragino Sans GB",sans-serif}</style>']
def label(px,py,txt,size=15,tint=ink,anchor='start',weight=400):
    svg.append(f'<text x="{px:.2f}" y="{py}" font-size="{size}" fill="{tint}" text-anchor="{anchor}" font-weight="{weight}">{escape(str(txt))}</text>')
def rect(px,py,w,h,fill,stroke='none'):
    svg.append(f'<rect x="{px:.2f}" y="{py}" width="{w:.2f}" height="{h}" fill="{fill}" stroke="{stroke}"/>')
def rule(a,b,c,d,tint=line,wd=1,dash=''):
    svg.append(f'<line x1="{a:.2f}" y1="{b}" x2="{c:.2f}" y2="{d}" stroke="{tint}" stroke-width="{wd}" stroke-dasharray="{dash}"/>')
def bar(span,y,fill,txt='',fg=ink,font=13):
    a,b=span;assert xmin<=a<=b<xmax,span
    rect(x(a),y-10,x(b+1)-x(a),20,fill,'white')
    if txt: label((x(a)+x(b+1))/2,y+4.5,txt,font,fg,'middle',600)
def chart(key,top,heading):
    source=data[key]
    frames=source['frames'][3:5];anchor=frames[0]['QK'][0]
    a,b=[{k:[v-anchor for v in s] for k,s in f.items()} for f in frames]
    delta=b['QK'][0]
    stall=source['input_wait'][3]
    overlap=source['consecutive_frame_overlap'][3]
    assert b['Q'][0]-a['V'][1]-1==stall
    label(23,top,heading,21,weight=650)
    label(right,top,f'帧启动间隔 {delta} 拍   /   输入握手间空闲 {stall} 拍   /   跨帧乘加重叠 {overlap} 拍',15,sub,'end')
    lo,hi=top+21,top+213
    if overlap:
        l,r=max(a['PV'][0],b['QK'][0]),min(a['PV'][1],b['QK'][1])
        rect(x(l),top+57,x(r+1)-x(l),66,'#F9ECDA')
    for tick in range(-80,161,20):
        rule(x(tick),lo,x(tick),hi,'#94A4AE' if tick==0 else line,1.35 if tick==0 else 1,'' if tick==0 else '4 4')
        label(x(tick),hi+18,str(tick).replace('-','−'),12,sub,'middle')
    ys=[top+n for n in (37,68,99,130,161,192)]
    for y,name in zip(ys,('输入握手','阵列 QKᵀ','阵列 PV','Softmax P 返回','输出握手','PE[0,0] 乘加')): label(left-12,y+5,name,15,ink,'end')
    for i,frame in enumerate((a,b),start=3):
        for m in ('Q','K','V'): bar(frame[m],ys[0],color[m],f'F{i} {m}',font=12)
        for j,m in enumerate(('QK','PV','P','out'),1):
            txt=f'F{i}' if m=='P' else f'F{i}   {frame[m][0]}–{frame[m][1]}'
            bar(frame[m],ys[j],color[m],txt,'white' if m in ('QK','PV') else ink)
        for m in ('QK','PV'): bar(frame[m+'0'],ys[5],color[m],f'F{i} {m}','white',11)
    if stall:
        band=(a['V'][1]+1,b['Q'][0]-1)
        text=f'等待 {stall} 拍' if stall>=16 else ''
        bar(band,ys[0],'#F7E7D6',text,'#784825',12)
    rule(left,hi,right,hi,'#ADBCC5')
    if overlap:
        label(left,hi+44,f't = {l}–{r}   F3 做 PV 的同时 F4 做 QKᵀ，共 {overlap} 拍。',15,'#91481F',weight=600)
    else:
        label(left,hi+44,f't = {a["out"][1]}   F3 最后一组输出握手，F4 在 t = {delta} 启动 QKᵀ。',15,sub)
    return anchor

rect(0,0,width,height,'white')
label(23,39,'单个 OS 阵列上连续两帧的时间线',26,weight=700)
label(23,67,'F3、F4 为同一连续输入批次的第 4、5 帧。每幅图的 t = 0 对齐该版本 F3 的首个 QKᵀ 乘加。',15,sub)
rule(23,82,right,82)
t0=chart('before',115,'优化前')
rule(23,393,right,393)
t1=chart('after',425,'优化后')
label(23,714,f'时间单位为时钟周期，区间含首末拍。t = 0 在两份 VCD 中分别对应仿真周期 {t0} 和 {t1}。',14,sub)
label(23,737,'两版均为公开端口的完整顶层仿真，源端持续供数、接收端持续 ready。乘加按各 PE 的实际有效输入与使能计数。',14,sub)
svg.append('</svg>')
p=dest/'timeline.svg'
p.write_text('\n'.join(svg)+'\n')
for ext,args in [('pdf',[]),('png',['--zoom','2'])]:
    subprocess.run(['rsvg-convert',*args,'--format',ext,'--output',str(p.with_suffix('.'+ext)),str(p)],check=True)
