# TOON output for CLI-owned JSON results. Internal state stays JSON/TSV.
def hex4:
  . as $n | "0123456789abcdef" as $h |
  [4096,256,16,1] | map(. as $p | $h[(($n/$p|floor)%16):((($n/$p|floor)%16)+1)]) | join("");
def quoted:
  "\"" + (explode | map(
    if .==92 then "\\\\" elif .==34 then "\\\"" elif .==10 then "\\n"
    elif .==13 then "\\r" elif .==9 then "\\t"
    elif .<32 then "\\u" + hex4 else [.]|implode end) | join("")) + "\"";
def str:
  if .=="" or test("^[ #\\-]|[ \\t]$|[:,\\\"\\\\\\[\\]{}\\x00-\\x1f]")
      or .=="true" or .=="false" or .=="null"
      or test("^[+-]?[0-9]+(?:\\.[0-9]+)?(?:e[+-]?[0-9]+)?$";"i")
  then quoted else . end;
def key: if test("^[A-Za-z_][A-Za-z0-9_.]*$") then . else quoted end;
def scalar: if type=="string" then str else tostring end;
def indent($n): "  " * $n;
def primitive: type!="object" and type!="array";
def tabular:
  if length==0 or (all(.[];type=="object")|not) then false else
    (.[0]|keys) as $keys | ($keys|index("")==null) and all(.[]; keys==$keys and all(.[];primitive)) end;
def enc($name;$depth):
  (if $name==null then "" else ($name|key) end) as $k |
  if type=="object" then
    if $name!=null then indent($depth)+$k+":" else empty end,
    (to_entries[] | .key as $key | .value | enc($key; $depth+(if $name==null then 0 else 1 end)))
  elif type=="array" then
    if length==0 then indent($depth)+(if $name==null then "[]" else $k+": []" end)
    elif all(.[];primitive) then indent($depth)+$k+"["+(length|tostring)+"]: "+(map(scalar)|join(","))
    elif tabular and ($name!=null or $depth==0) then
      (.[0]|keys_unsorted) as $fields |
      indent($depth)+$k+"["+(length|tostring)+"]{"+($fields|map(key)|join(","))+"}:",
      (.[] | . as $row | indent($depth+1)+($fields|map($row[.]|scalar)|join(",")))
    else
      indent($depth)+$k+"["+(length|tostring)+"]:",
      (.[] | if primitive then indent($depth+1)+"- "+scalar
       elif type=="object" and length>0 then
         to_entries as $pairs | $pairs[0] as $first |
         if ($first.value|primitive) then
           indent($depth+1)+"- "+($first.key|key)+": "+($first.value|scalar),
           ($pairs[1:][] | .key as $key | .value | enc($key;$depth+2))
         else
           [$first.value|enc($first.key;$depth+2)] as $lines |
           indent($depth+1)+"- "+($lines[0]|ltrimstr(indent($depth+2))),
           ($lines[1:][]),
           ($pairs[1:][] | .key as $key | .value | enc($key;$depth+2))
         end
       elif type=="object" then indent($depth+1)+"-"
       else [enc(null;$depth+1)] as $lines |
         indent($depth+1)+"- "+($lines[0]|ltrimstr(indent($depth+1))),
         ($lines[1:][]) end)
    end
  else indent($depth)+(if $name==null then "" else $k+": " end)+scalar end;
enc(null;0)
