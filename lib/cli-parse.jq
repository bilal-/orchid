# One argv walk shared by dispatch and direct verb admission. Values of
# semantic options are consumed before looking for help/presentation flags.
def fail($s): error($s);
def group_hint($m;$a):
 ([$m.commands[].path | . as $p | range(0;($p|length)) as $n |
   select($a[0:$n]==$p[0:$n]) | $p[0:$n]] | sort_by(length) | last // []) as $prefix |
 ($prefix|join(" ")) + (if ($prefix|length)>0 then " " else "" end) +
 "{" + ([$m.commands[].path | select(.[0:($prefix|length)]==$prefix) | .[($prefix|length)]] | unique | join("|")) + "}";
def presentation: {"--json":0,"--full":0,"--fields":1,"--limit":1,"--request-id":1};
try (. as $m | $argv as $a |
([$m.commands[] | . as $c | select(($c.path|length)>0 and $a[0:($c.path|length)] == $c.path)] | sort_by(.path|length) | last) as $matched |
($a | index("--help") // index("-h")) as $help_at |
(if $matched != null then $matched
 elif ([$m.commands[] | select(.path==[])]|length)>0 then ([$m.commands[] | select(.path==[])]|first)
 elif $help_at != null and ([$m.commands[] | select(.path[0:$help_at] == $a[0:$help_at])]|length)>0 then
   {path:$a[0:$help_at],kind:"group",options:{},usage:("usage: orchid " + $verb + " " + (if $help_at>0 then ($a[0:$help_at]|join(" "))+" " else "" end) + "<command>"),
    commands:([$m.commands[] | select(.path[0:$help_at] == $a[0:$help_at]) | {usage,path,description:(.description // "")}]),
    examples:([$m.commands[] | select(.path[0:$help_at] == $a[0:$help_at]) | .examples[0] // empty][0:3])}
 elif ($a|length)==0 or ($a[0]|startswith("-")) then
   ([$m.commands[] | select(.path == ($m.default // []))] | first)
 else ([$m.commands[] | select(.path == [])] | first) end) as $c |
if $c == null then fail("unknown command form: orchid " + $verb + " " + ($a|join(" ")) + "; usage: orchid " + $verb + " " + group_hint($m;$a)) else . end |
(if $matched != null then ($c.path|length) elif $c.kind=="group" then ($c.path|length) else 0 end) as $consume |
($c.options // {}) as $public |
($public + (if $raw then ($c.internal_options // {}) else {} end)) as $known |
($a[$consume:]) as $rest |
reduce range(0; $rest|length) as $i
 ({skip:0,args:[],opts:[],pos:[],seen:{},help:false,view:{format:$format,full:false,limit:($c.default_limit // 100),fields:null,request_id:null}};
 if .skip>0 then .skip-=1 else
 $rest[$i] as $x |
 if ($x=="--help" or $x=="-h") then .help=true
 elif $x=="--" then .args += $rest[$i:] | .pos += $rest[($i+1):] | .skip=($rest|length)
 elif ($x|startswith("-")) and $x!="-" then
   ($x|split("="))[0] as $flag |
   (if ($x|contains("=")) then ($x|split("=")[1:]|join("=")) else null end) as $inline |
   (if ($known|has($flag)) then $known[$flag]
    elif ($raw|not) and (presentation|has($flag)) then presentation[$flag]
    else fail("unknown flag " + $flag + "; run orchid " + $verb + " " + ($c.path|join(" ")) + " --help") end) as $arity |
   (if $arity==1 then
      if $inline!=null then $inline
      elif ($i+1)<($rest|length) then $rest[$i+1]
      else fail($flag + " requires a value") end
    elif $inline!=null then fail($flag + " takes no value") else null end) as $value |
   (if $arity==1 and $inline==null then .skip=1 else . end) |
   if ($raw|not) and (presentation|has($flag)) and (($known|has($flag))|not) then
     if $flag=="--json" then .view.format="json"
     elif $flag=="--full" then .view.full=true
     elif $flag=="--limit" then
       if ($value|test("^[1-9][0-9]*$")) then .view.limit=($value|tonumber)
       else fail("--limit requires a positive integer") end
     elif $flag=="--fields" then .view.fields=($value|split(","))
     elif $flag=="--request-id" then
       if ($value|test("^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")) then .view.request_id=$value
       else fail("--request-id requires 1-128 letters, digits or _.:- starting with a letter or digit") end
     else . end
   else
     if (.seen|has($flag)) and (($c.repeatable_options // []|index($flag))==null) then fail("duplicate option " + $flag + "; " + $c.usage) else . end |
     .seen[$flag]=$value | (if $inline!=null then [$flag,$value] elif $arity==1 then [$flag,$value] else [$flag] end) as $normalized |
     .args += $normalized | .opts += $normalized end
 elif .pos!=null then .pos+=[$x] | .args+=[$x] else . end end)
| . as $parsed |
if .help then .
elif ([($c.required_options // [])[] | . as $flag | select(($parsed.seen|has($flag))|not)]|length)>0 then fail(($c.path[-1] // $verb) + " requires " + ([($c.required_options // [])[] | select(. as $flag | ($parsed.seen|has($flag))|not)]|join(", ")) + "; " + $c.usage)
elif (($c.required_any_options // [])|length)>0 and ([($c.required_any_options // [])[] | select(. as $flag | $parsed.seen|has($flag))]|length)==0 then
   fail(($c.path[-1] // $verb) + " requires one of " + ($c.required_any_options|join(", ")) + "; " + $c.usage)
 elif ([($c.exclusive_options // [])[] | . as $group | select([$group[] | select(. as $flag | $parsed.seen|has($flag))]|length>1)]|length)>0 then
   fail("mutually exclusive options cannot be combined; " + $c.usage)
elif ($raw|not) and ($parsed.seen|has("--watch")) then
   fail("--watch streams indefinitely; use orchid jobs ls for a bounded snapshot or orchid --raw jobs ls --watch for the explicit interactive stream")
 elif ($c.kind // "") == "group" then fail("a subcommand is required; " + $c.usage)
elif (.pos|length) < ($c.min_args // 0) then fail("missing argument; " + $c.usage)
elif $c.max_args != null and (.pos|length)>$c.max_args then fail("unexpected argument " + (.pos[$c.max_args]) + "; " + $c.usage)
else . end |
if .view.fields != null then
  (if .help then ["usage","commands","description","options","output","examples","notes","next"] else ($c.fields // $c.output_fields // ["text"]) end) as $fields |
  ([.view.fields[] | . as $field | select(($fields|index($field)) == null)]) as $bad |
  if ($bad|length)>0 then fail("unknown output field " + ($bad|join(","))) else . end
else . end |
{command:($c + {notes:(($m.notes // []) + ($c.notes // []))}),argv:($c.path + (if .help then .args else
   ($c.positionals_prefix // $c.min_args // 0) as $prefix |
   .pos[0:$prefix] + .opts +
   (if (.pos[$prefix:]|length)>0 and any(.pos[$prefix:][];startswith("-")) then ["--"] else [] end) + .pos[$prefix:]
   end)),wire_argv:($c.path + (if .help then .args else .opts + (if (.pos|length)>0 then ["--"] else [] end) + .pos end)),options_argv:.opts,help:.help,view:.view,positionals:.pos}
) catch {error:.}
