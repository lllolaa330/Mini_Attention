"""Render the measured Mini_Attention timeline. Run after extract_timeline.py."""
import json
from pathlib import Path

import matplotlib as mpl
mpl.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.patches import Patch, Rectangle

HERE = Path(__file__).resolve().parent
flows = json.loads((HERE / "timeline.json").read_text())["flows"]
font_file = next(iter(sorted((Path.home() / "Library/Fonts").glob("SourceHanSansCN-Regular*.otf"))), None)
if font_file:
    font_manager.fontManager.addfont(str(font_file))
    family = font_manager.FontProperties(fname=str(font_file)).get_name()
else:
    family = "Noto Sans CJK SC"
ink, muted, grid = "#20313F", "#526674", "#DBE3E8"
colors = {"input":"#C9DFEF", "weights":"#ACC8CD", "gemm":"#AFD6BF",
          "softmax":"#D7CBE7", "wait":"#E9EDF0", "output":"#F3C59D", "clear":"#526674"}
mpl.rcParams.update({"font.family": [family,"DejaVu Sans"], "font.size": 11,
                     "text.color": ink, "axes.labelcolor": muted, "xtick.color": muted,
                     "ytick.color": ink, "pdf.fonttype":42, "svg.fonttype":"path",
                     "mathtext.fontset":"dejavusans", "axes.unicode_minus":False})
fig = plt.figure(figsize=(12.9, 7.3), facecolor="white")
fig.text(.04,.934, "Mini_Attention 的流水时间线", fontsize=24, weight="bold")
fig.text(.041,.885, "16 × 16 全 FP16   ·   连续输入，无输出背压   ·   首帧首个输入握手记为第 1 拍", fontsize=12, color=muted)

def make_axis(box, bounds, ticks, ys, labels):
    ax = fig.add_axes(box)
    ax.set(xlim=bounds, ylim=(-.52, max(ys)+.56))
    ax.set_yticks(ys, labels, fontsize=11)
    ax.set_xticks(ticks, [str(v) for v in ticks], fontsize=10)
    ax.tick_params(axis="y", length=0, pad=7)
    ax.tick_params(axis="x", length=3, width=.65, color=grid)
    ax.set_axisbelow(True)
    ax.xaxis.grid(True, linewidth=.6, color=grid)
    for loc in ("right","top","left"):
        ax.spines[loc].set_visible(False)
    ax.spines["bottom"].set_color(grid)
    return ax

def bar(ax, y, start, end, kind, label="", fontsize=10, height=.64):
    ax.add_patch(Rectangle((start-.5,y-height/2),end-start+1,height,
                           facecolor=colors[kind], edgecolor="white", linewidth=.55, zorder=3))
    if label:
        ax.text((start+end)/2,y,label,ha="center",va="center",fontsize=fontsize,zorder=4)

def stagebar(ax,y,stage,kind,label=""):
    bar(ax,y,stage["start"],stage["end"],kind,label)

def get_map(flow):
    result = {stage["name"]:stage for stage in flow["top_states"]}
    result["SOFTMAX"]={"start":result["SM_START"]["start"], "end":result["SM_WAIT"]["end"]}
    return result

overview = make_axis([.119,.509,.841,.265], (.5,1024.5), [1,257,513,769,1024],
                     [4,3,2,1,0], ["输入端口","OS 计算","OS 输出","WS 计算","WS 输出"])
for key,label in zip(("Q","K","V","Q_next"),
                     (r"帧 0 · $Q$   1–256",r"帧 0 · $K$   257–512",
                      r"帧 0 · $V$   513–768",r"帧 1 · $Q$   769–1024")):
    stagebar(overview,4,flows["os"]["input"][key],"input",label)
for mode,y in (("os",3),("ws",1)):
    flow=flows[mode]
    stages=get_map(flow)
    for key,kind in [("CLEAR_QK","clear"),("LOAD_W_QK","weights"),("RUN_QK","gemm"),
                     ("SOFTMAX","softmax"),("WAIT_V","wait"),("CLEAR_PV","clear"),
                     ("LOAD_W_PV","weights"),("RUN_PV","gemm")]:
        if key not in stages: continue
        stage=stages[key]
        label=f"等 V 收齐 · {stage['cycles']} 拍" if key=="WAIT_V" else ""
        stagebar(overview,y,stage,kind,label)
    out=flow["output"]
    bar(overview,y-1,out["first"],out["last"],"output")
    overview.text(out["last"]+8,y-1,f"{out['first']}–{out['last']}",va="center",fontsize=10,color=muted)

legend = [Patch(facecolor=colors[k], edgecolor="none",label=text) for k,text in
          [("weights","WS 装权"),("gemm","矩阵乘"),("softmax","Softmax（含启动）"),
           ("output","输出握手"),("clear","阵列清零（1 拍）")]]
fig.legend(handles=legend, loc="upper left", bbox_to_anchor=(.112,.85),
           ncol=5, frameon=False, handlelength=1.23, handleheight=.75,
           handletextpad=.45, columnspacing=1.65, borderpad=0, fontsize=10)

fig.text(.041,.395,r"收 $V_0$ 时计算 $Q_0 K_0^{\mathsf{T}}$ 和 Softmax",fontsize=15,weight="bold")
fig.text(.543,.395,r"收 $Q_1$ 时计算 $P_0 V_0$ 并输出 $Y_0$",fontsize=15,weight="bold")
left = make_axis([.119,.151,.355,.202],(512.5,600.5),[513,530,550,570,590],
                 [3,2,1,0],["OS 阵列","Softmax","WS 阵列","Softmax"])
right = make_axis([.612,.151,.348,.202],(768.5,841.5),[769,785,801,817,833],
                  [3,2,1,0],["OS 阵列","输出","WS 阵列","输出"])
for mode,y in (("os",3),("ws",1)):
    flow=flows[mode];s=get_map(flow)
    for ax,clear,load,run,title in [(left,"CLEAR_QK","LOAD_W_QK","RUN_QK",r"$QK^{\mathsf{T}}$"),
                                    (right,"CLEAR_PV","LOAD_W_PV","RUN_PV",r"$PV$")]:
        stagebar(ax,y,s[clear],"clear")
        if load in s: stagebar(ax,y,s[load],"weights","装权")
        stagebar(ax,y,s[run],"gemm",f"{title}   {s[run]['start']}–{s[run]['end']}")
    st=s["SOFTMAX"]
    stagebar(left,y-1,st,"softmax",f"{st['start']}–{st['end']}")
    out=flow["output"]
    bar(right,y-1,out["first"],out["last"],"output",f"{out['first']}–{out['last']} · 31 拍")
for ax in (left,right):
    ax.axhline(1.5,color=grid,linewidth=.65)
    ax.set_xlabel("相对时钟周期（拍）",fontsize=10,labelpad=5)
fig.text(.041,.035,"Icarus Verilog 12.0  ·  第 0 帧，全零定向用例  ·  区间含首尾；每帧 31 次输出握手传完 256 个 FP16 元素。",color=muted,fontsize=10)
for ext in ("svg","pdf","png"):
    fig.savefig(HERE/f"mini_attention_timeline.{ext}", dpi=350, facecolor="white")
