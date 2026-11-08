import struct,zlib,sys

def rgb565(v):
    r=((v>>11)&31)*255//31; g=((v>>5)&63)*255//63; b=(v&31)*255//31
    return (r,g,b,255)

def dxt1(block,out,ox,oy,w,h):
    c0,c1,idx=struct.unpack('<HHI',block)
    a=rgb565(c0); b=rgb565(c1)
    cols=[a,b]
    if c0>c1: cols+= [tuple((2*a[i]+b[i])//3 for i in range(3))+(255,), tuple((a[i]+2*b[i])//3 for i in range(3))+(255,)]
    else: cols+= [tuple((a[i]+b[i])//2 for i in range(3))+(255,), (0,0,0,0)]
    for j in range(4):
        for i in range(4):
            k=(idx>>(2*(4*j+i)))&3
            x,y=ox+i,oy+j
            if x<w and y<h: out[y*w+x]=cols[k]

def dxt5(block,out,ox,oy,w,h):
    a0,a1=block[0],block[1]
    ac=[a0,a1]
    if a0>a1:
        for i in range(1,6): ac.append(((7-i)*a0+i*a1)//7)
    else:
        for i in range(1,4): ac.append(((5-i)*a0+i*a1)//5)
        ac += [0,255]
    bits=int.from_bytes(block[2:8],'little')
    c0,c1,idx=struct.unpack_from('<HHI',block,8)
    b=rgb565(c0); c=rgb565(c1)
    cols=[b,c]
    cols+=[tuple((2*b[i]+c[i])//3 for i in range(3))+(255,), tuple((b[i]+2*c[i])//3 for i in range(3))+(255,)]
    for j in range(4):
        for i in range(4):
            k=(bits>>(3*(4*j+i)))&7
            kc=(idx>>(2*(4*j+i)))&3
            x,y=ox+i,oy+j
            if x<w and y<h:
                col=cols[kc]; out[y*w+x]=(col[0],col[1],col[2],ac[k])

def write_png(path,w,h,pix):
    raw=b''.join(b'\x00'+bytes(sum((list(pix[y*w+x]) for x in range(w)),[])) for y in range(h))
    def chunk(t,d):
        c=t+d
        return struct.pack('>I',len(d))+c+struct.pack('>I',zlib.crc32(c)&0xffffffff)
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw,6))+chunk(b'IEND',b'')
    open(path,'wb').write(png)

d=open(sys.argv[1],'rb').read()
h,w=struct.unpack_from('<II',d,12)[0],struct.unpack_from('<II',d,12)[1]
h=struct.unpack_from('<I',d,12)[0]; w=struct.unpack_from('<I',d,16)[0]
fourcc=d[84:88]
bs=8 if fourcc==b'DXT1' else 16
out=[(0,0,0,255)]*(w*h)
pos=128; bw=(w+3)//4; bh=(h+3)//4
for by in range(bh):
    for bx in range(bw):
        blk=d[pos:pos+bs]; pos+=bs
        (dxt1 if fourcc==b'DXT1' else dxt5)(blk,out,bx*4,by*4,w,h)
write_png(sys.argv[2],w,h,out)
print(sys.argv[2],w,h,fourcc.decode(),len(d))
