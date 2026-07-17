"""Compare archetypes by time-to-first-prestige under the APPLIED config, each with its own
geometry, upgrade set, and bet strategy (chaos: low bet + flat combo; others: scale with bet).
Combo stays ABSOLUTE (chaos's low-bet/high-combo identity depends on it)."""
import sys; sys.path.insert(0, 'python')
from pathlib import Path
import balance as B, progression as P

BUILDS = B.parse(Path('tests/2026-06-26.txt'))
CFG = P.Proposed; CB = 5
THRESH = B.PRESTIGE_SCALE * (CB ** (1/B.PRESTIGE_EXP))
TABLE = CFG.slot_half + CFG.slot_half[::-1]

def nearest(angle, size, elast, arc, ph):
    return min(BUILDS, key=lambda b:(b.pegheat!=ph, abs(abs(b.angle)-abs(angle)),
               abs(b.size-size), abs(b.elast-elast), abs(b.arc-arc)))

def near_ph(t): return min((0,6,12), key=lambda k:abs(k-t))

def banked(axes, tiers):
    b = nearest(*axes, near_ph(tiers.get('PegHeat',0)))
    frac=[b.targets.get(s,0)/b.n for s in range(18)]
    e=sum(frac[s]*B.slot_eff_mult(TABLE,s,CFG.jackpot_mult) for s in range(18))
    hf=B.PEGHEAT_PERTIER*tiers.get('PegHeat',0)
    H=max(hf*(b.hot*B.HOT_HEAT+b.cold*B.COLD_HEAT),-0.75); hm=max(0,1+H)
    add=1+P.badd(CFG,tiers.get('BaseAdditive',0))
    per_value=e*hm*add
    mx=P.max_bet(CFG,tiers.get('MaxBet',0)); bet=mx if per_value>=1 else P.MIN_BET
    cb=b.combo*B.flat_per_bounce(tiers.get('FlatRate',0)) if b.combo>=B.MIN_COMBO else 0
    bk=(bet*e*hm+cb)*add + B.TRICKLE_FRAC*mx
    return bk, bet

def sim(name, axes, allowed):
    tiers={t:0 for t in allowed}; bal=600.0; life=0.0; t=0.0; dt=0.5
    while life<THRESH and t<3600*8:
        bk,bet=banked(axes,tiers); d=P.launch_delay(CFG,tiers.get('Frequency',0))
        bal+=(bk-bet)/d*dt; life+=bk/d*dt; t+=dt
        best,broi=None,0
        bl=bk/d
        for tr in allowed:
            if tiers[tr]>=P.TIER_CAP[tr]: continue
            c=P.cost_to_raise(CFG,tr,tiers[tr])
            if c>bal: continue
            tiers[tr]+=1; nb,_=banked(axes,tiers); tiers[tr]-=1
            roi=(nb/P.launch_delay(CFG,tiers.get('Frequency',0))-bl)/c
            if roi>broi: best,broi=tr,roi
        if best: bal-=P.cost_to_raise(CFG,best,tiers[best]); tiers[best]+=1
    return t/60, tiers

print(f"threshold LB={THRESH:,.0f}  (lower time = stronger build)\n")
for name,axes,allowed in [
    ("hybrid",   (0,0.75,0.5,5),  ["MaxBet","BaseAdditive","Frequency"]),
    ("chaos",    (0,1.0,1.0,80),  ["FlatRate","Frequency","BaseAdditive"]),
    ("targeting",(65,0.5,0.0,5),  ["MaxBet","BaseAdditive","PegHeat","Frequency"]),
]:
    mins,tiers=sim(name,axes,allowed)
    print(f"  {name:9}: {mins:6.1f} min   {tiers}")
