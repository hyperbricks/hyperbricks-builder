# Strict JSON reader and SemVer selector. Only expected release fields are used.
function die(s) { print "Invalid release metadata: " s > "/dev/stderr"; exit 1 }
function ws() { while (substr(src,pos,1) ~ /[ \t\r\n]/ && pos<=length(src)) pos++ }
function str(   c,e,out,h,i,n) {
 if (substr(src,pos++,1)!="\"") die("string expected")
 out=""
 while(pos<=length(src)) {
  c=substr(src,pos++,1)
  if(c=="\"") return out
  if(c=="\\") {
   e=substr(src,pos++,1)
   if(e=="u") {
    h=substr(src,pos,4); if(h !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) die("unicode escape")
    pos+=4; n=0; h=tolower(h)
    for(i=1;i<=4;i++) n=n*16+index("0123456789abcdef",substr(h,i,1))-1
    c=(n>=32 && n<127)?sprintf("%c",n):"?"
   } else if(e=="\"" || e=="\\" || e=="/") c=e
   else if(e ~ /^[bfnrt]$/) c="?"
   else die("escape")
  } else if(c ~ /[[:cntrl:]]/) die("control character")
  out=out c
 }
 die("unterminated string")
}
function field(path,v,   a,n,r,k) {
 n=split(path,a,"/"); r=a[2]; k=a[3]
 if(n==3 && (k=="tag_name" || k=="draft")) data[r,k]=v
 if(n==5 && k=="assets") asset[r,a[4],a[5]]=v
}
function value(path,depth,   c,k,v,i) {
 if(depth>80) die("nesting")
 ws(); c=substr(src,pos,1)
 if(c=="{") {
  pos++; ws(); if(substr(src,pos,1)=="}") {pos++;return}
  while(1) {
   ws();k=str();ws();if(substr(src,pos++,1)!=":") die("colon")
   value(path "/" k,depth+1);ws();c=substr(src,pos++,1)
   if(c=="}") return
   if(c!=",") die("object separator")
  }
 } else if(c=="[") {
  pos++;ws();if(substr(src,pos,1)=="]") {pos++;return}
  i=0
  while(1) {
   if(depth==0) value("/" ++count,depth+1); else value(path "/" i++,depth+1)
   ws();c=substr(src,pos++,1);if(c=="]") return
   if(c!=",") die("array separator")
  }
 } else {
  if(c=="\"") v=str()
  else {
   v="";while(pos<=length(src) && substr(src,pos,1) !~ /[ \t\r\n,}\]]/) v=v substr(src,pos++,1)
   if(v!="true" && v!="false" && v!="null" && v !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/) die("scalar")
  }
  field(path,v)
 }
}
function numeric(a,b) { if(length(a)!=length(b)) return length(a)>length(b)?1:-1; return a==b?0:("x" a>"x" b?1:-1) }
function valid(t,   b,a,i,n) {
 if(t !~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$/) return 0
 b=t;sub(/^[^-]*-?/,"",b)
 if(b!="") {n=split(b,a,".");for(i=1;i<=n;i++) if(a[i]=="" || a[i] ~ /^0[0-9]+$/) return 0}
 return 1
}
function compare(a,b,   aa,bb,pa,pb,na,nb,i,c) {
 pa=a;pb=b;sub(/^[^-]*-?/,"",pa);sub(/^[^-]*-?/,"",pb)
 sub(/-.*/,"",a);sub(/-.*/,"",b);sub(/^v/,"",a);sub(/^v/,"",b)
 split(a,aa,".");split(b,bb,".")
 for(i=1;i<=3;i++){c=numeric(aa[i],bb[i]);if(c) return c}
 if(pa==pb) return 0
 if(pa=="") return 1
 if(pb=="") return -1
 na=split(pa,aa,".");nb=split(pb,bb,".")
 for(i=1;i<=na && i<=nb;i++) {
  if(aa[i]==bb[i]) continue
  if(aa[i] ~ /^[0-9]+$/ && bb[i] ~ /^[0-9]+$/) return numeric(aa[i],bb[i])
  if(aa[i] ~ /^[0-9]+$/) return -1
  if(bb[i] ~ /^[0-9]+$/) return 1
  return "x" aa[i]>"x" bb[i]?1:-1
 }
 return na>nb?1:-1
}
function hash(v) {return length(v)==71 && v ~ /^sha256:[0-9a-f]+$/}
{src=src $0 "\n"}
END {
 pos=1; ws(); while(pos<=length(src)){if(substr(src,pos,1)!="[") die("release array expected");value("",0);ws()}
 split("darwin_amd64 darwin_arm64 linux_amd64 linux_arm64 windows_amd64",platforms," ")
 for(r=1;r<=count;r++) {
  tag=data[r,"tag_name"];if(data[r,"draft"]!="false" || !valid(tag)) continue
  if(wanted!="" && tag!=wanted) continue
  delete names
  for(k in asset){split(k,parts,SUBSEP);if(parts[1]==r && parts[3]=="name") {
   name=asset[k];digest=asset[r,parts[2],"digest"]
   if(asset[r,parts[2],"state"]=="uploaded" && hash(digest)) names[name]=substr(digest,8)
  }}
  complete=1
  for(i=1;i<=5;i++){ext=platforms[i] ~ /^windows/?".zip":".tar.gz";name="hyperbricks_" tag "_" platforms[i] ext;if(!(name in names) || !((name ".sha256") in names)) complete=0}
  if(!complete) continue
  name="hyperbricks_" tag "_" platform ".tar.gz"
  if(best=="" || compare(tag,best)>0){best=tag;besthash=names[name];sidehash=names[name ".sha256"]}
 }
 if(best=="") {print "No complete published HyperBricks release found" > "/dev/stderr";exit 1}
 print best, besthash, sidehash
}
