"""Chaos viability if FlatRate scales exponentially & uncapped like MaxBet (low-bet identity kept)."""
import sys; sys.path.insert(0,'python')
from pathlib import Path
import balance as B, progression as P

BUILDS=B.parse(Path('tests/2026-06-26.txt'))
CB=5; THRESH=B.PRESTIGE_SCALE*(CB**(1/B.PRESTIGE_EXP))

class CFG(P.Proposed):
    cost=dict(P.Proposed.cost)
    cost["FlatRate"]=(260.0,1.9)     # cost grows like MaxBet's, so it's gated not explosive
    cost["Frequency"]=(230.0,1.9)    # fix: was 4.5 (never bought)
TABLE=CFG.slot_half+CFG.slot_half[::-1]
B.FLATRATE_PERTIER=1.5               # match MaxBet's income growth
B.FLATRATE_BASE=0.3
CAP={"Frequency":12,"Size":12,"MaxBet":30,"BaseAdditive":12,"FlatRate":30,"PegHeat":12}  # FlatRate uncapped

def nearest(a,s,e,ar,ph): return min(BUILDS,key=lambda b:(b.pegheat!=ph,abs(abs(b.angle)-abs(a)),abs(b.size-s),abs(b.elast-e),abs(b.arc-ar)))
def near_ph(t): return min((0,6,12),key=lambda k:abs(k-t))
def banked(axes,tiers):
    b=nearest(*axes,near_ph(tiers.get('PegHeat',0)))
    frac=[b.targets.get(s,0)/b.n for s in range(18)]
    e=sum(frac[s]*B.slot_eff_mult(TABLE,s,CFG.jackpot_mult) for s in range(18))
    H=max(B.PEGHEAT_PERTIER*tiers.get('PegHeat',0)*(b.hot*1-b.cold),-0.75); hm=max(0,1+H)
    add=1+P.badd(CFG,tiers.get('BaseAdditive',0)); per=e*hm*add
    mx=P.max_bet(CFG,tiers.get('MaxBet',0)); bet=mx if per>=1 else P.MIN_BET
    cb=b.combo*B.flat_per_bounce(tiers.get('FlatRate',0)) if b.combo>=B.MIN_COMBO else 0
    return (bet*e*hm+cb)*add+B.TRICKLE_FRAC*mx, bet
def sim(axes,allowed):
    tiers={t:0 for t in allowed}; bal=600.0; life=0.0; t=0.0
    while life<THRESH and t<3600*10:
        bk,bet=banked(axes,tiers); d=P.launch_delay(CFG,tiers.get('Frequency',0))
        bal+=(bk-bet)/d*0.5; life+=bk/d*0.5; t+=0.5
        best,broi=None,0; bl=bk/d
        for tr in allowed:
            if tiers[tr]>=CAP[tr]: continue
            c=P.cost_to_raise(CFG,tr,tiers[tr])
            if c>bal: continue
            tiers[tr]+=1; nb,_=banked(axes,tiers); tiers[tr]-=1
            roi=(nb/P.launch_delay(CFG,tiers.get('Frequency',0))-bl)/c
            if roi>broi: best,broi=tr,roi
        if best: bal-=P.cost_to_raise(CFG,best,tiers[best]); tiers[best]+=1
    return t/60,tiers
for name,axes,allowed in [
    ("hybrid",(0,0.75,0.5,5),["MaxBet","BaseAdditive","Frequency"]),
    ("chaos",(0,1.0,1.0,80),["FlatRate","Frequency","BaseAdditive"]),
    ("targeting",(65,0.5,0.0,5),["MaxBet","BaseAdditive","PegHeat","Frequency"]),
]:
    m,ti=sim(axes,allowed); print(f"  {name:9}: {m:6.1f} min   {ti}")
