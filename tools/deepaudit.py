import sys, struct, math, subprocess, hashlib, json, os
from collections import Counter, defaultdict

MAPCONV="/mnt/c/Users/Shifty/DEV-AI/Research-mapconv/mapconv/mapconv.exe"

def tables(path):
    out=subprocess.run([MAPCONV,"inspect","--input",path.replace("/mnt/c/","C:/")],capture_output=True,text=True,timeout=600).stdout
    for line in out.splitlines():
        if line.startswith("tables:"):
            toks=line.replace(","," ").split()
            d={}
            for i,t in enumerate(toks):
                if t=="names": d["names"]={"count":int(toks[i+1]),"off":int(toks[i+2][1:])}
                if t=="imports": d["imports"]={"count":int(toks[i+1]),"off":int(toks[i+2][1:])}
                if t=="exports": d["exports"]={"count":int(toks[i+1]),"off":int(toks[i+2][1:])}
            return d
    raise RuntimeError("no tables")

def read_names(d, t):
    names=[]; p=t["off"]
    for _ in range(t["count"]):
        n=struct.unpack_from('<i',d,p)[0]; p+=4
        if n<0:
            ln=-n; s=d[p:p+ln*2].decode('utf-16-le',errors='replace').rstrip('\x00'); p+=ln*2
        else:
            s=d[p:p+n].decode('latin1').rstrip('\x00'); p+=n
        p+=8
        names.append(s)
    return names

def imports(d, t, names):
    out=[]; p=t["off"]
    for _ in range(t["count"]):
        cp,cpn,cn,cnn,outer,on,onn=struct.unpack_from('<iIiIiIi',d,p)
        out.append({"class_name":names[cn] if 0<=cn<len(names) else "?", "object_name":names[on] if 0<=on<len(names) else "?"})
        p+=28
    return out

def exports(d, t, names):
    out=[]; p=t["off"]
    for i in range(t["count"]):
        base=p
        cls,sup,outer,nm,nmb,arch=struct.unpack_from('<iiiiii',d,p)
        flags,=struct.unpack_from('<Q',d,p+24)
        size,off,eflags=struct.unpack_from('<iii',d,p+32)
        q=p+44
        ncnt=struct.unpack_from('<i',d,q)[0]; q+=4+ncnt*4+16+4
        out.append({"i":i,"class_idx":cls,"name_idx":nm,"outer":outer,"size":size,"off":off,"flags":flags})
        p=q
    return out

def clsname(e, imps, names):
    ci=e["class_idx"]
    if ci<0:
        k=-ci-1
        return imps[k]["object_name"] if 0<=k<len(imps) else "?"
    if 0<ci<=len(names): return names[ci-1]
    return "?"

def entropy(b, cap=1<<20):
    if not b: return 0.0
    c=Counter(b[:cap]); n=len(b[:cap])
    return -sum(v/n*math.log2(v/n) for v in c.values())

def markers(b, cap=1<<20):
    s=b[:cap]; m=[]
    if b'\x78\x9c' in s or b'\x78\xda' in s: m.append("zlib")
    if b'\xc1\x83\x2a\x9e' in s: m.append("lzo-chunk")
    if b'OggS' in s: m.append("ogg")
    if s[:4]==b'RIFF' or b'WAVE' in s[:64]: m.append("riff")
    if b'\xff\xff\xff\xff' in s[:64]: m.append("ffff-marker")
    return m

if __name__=="__main__":
    path=sys.argv[1]
    d=open(path,'rb').read()
    t=tables(path); names=read_names(d,t["names"]); imps=imports(d,t["imports"],names); exps=exports(d,t["exports"],names)
    targets={"SkeletalMesh","AnimSequence","SoundNodeWave","StaticMeshComponent","DecalComponent","Speedline","Level","BrushComponent"}
    rows=[]
    for e in exps:
        cn=clsname(e,imps,names)
        if cn in targets and e["size"]>0:
            if not (0<=e["off"]<=len(d) and e["off"]+e["size"]<=len(d)): continue
            b=d[e["off"]:e["off"]+min(e["size"],1<<20)]
            rows.append({"class":cn,"size":e["size"],"off":e["off"],"name":names[e["name_idx"]] if 0<=e["name_idx"]<len(names) else "?",
                         "entropy":round(entropy(b),2),"markers":markers(b),"head":b[:16].hex()})
    agg=defaultdict(lambda:{"n":0,"bytes":0,"sizes":[]})
    for r in rows:
        a=agg[r["class"]]; a["n"]+=1; a["bytes"]+=r["size"]; a["sizes"].append(r["size"])
    print(path)
    for c,a in sorted(agg.items(), key=lambda kv:-kv[1]["bytes"]):
        s=sorted(a["sizes"])
        print(" %-22s n=%-5d bytes=%-12d min=%-9d med=%-9d max=%-9d" % (c,a["n"],a["bytes"],s[0],s[len(s)//2],s[-1]))
    big=[r for r in rows if r["size"]>1_000_000][:12]
    for r in big:
        print("  %-22s %-28s size=%-10d ent=%-5s %s head=%s" % (r["class"],r["name"][:28],r["size"],r["entropy"],",".join(r["markers"]) or "-",r["head"]))
