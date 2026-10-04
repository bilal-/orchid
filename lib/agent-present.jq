# Count before limiting and project known schemas at the presentation boundary.
def shorten:
  if type=="string" and length>1250 and ($view.full|not) then
    . as $text | .[0:1250] + "… [" + ($text|length|tostring) + " characters; use --full]"
  else . end;
def listview($fields):
  .items as $rows |
  .next=([(.next // [])[] | . as $hint |
    if ($hint|contains("<id>")) and ($rows|length)>0 then
      $rows[0:3][] | (if ($hint|startswith("orchid task")) then (.task // .id) else .id end) as $id |
      if $id!=null then $hint|gsub("<id>";($id|@sh)) else empty end
    elif ($hint|test("<[^>]+>")) then empty else $hint end]) |
  .count=(.count // (.items|length)) | .total=(.total // .count) |
  ($fields // .default_fields // .fields) as $selected |
  if $selected != null then .items |= map(with_entries(select(.key as $key | $selected|index($key)))) else . end |
  if ($view.full|not) then .items=.items[0:$view.limit] else . end |
  if (.items|length)<.total then .next=((.next // []) + [($view.command // "Repeat this command") + " --full"]) else . end |
  .next=((.next // [])|unique) | .shown=(.items|length) | del(.fields,.default_fields) |
  if .items==[] then .empty="0 results" else . end;
(if .items != null then listview($view.fields // $command.default_fields // $command.fields)
 elif $view.fields != null then with_entries(select(.key as $key | $key=="request" or ($view.fields|index($key)))) else . end)
| walk(if type=="object" and .items!=null then listview(null) else shorten end)
| if ([..|strings|select(endswith("characters; use --full]"))]|length)>0 then
    .next=((.next // []) + [($view.command // "Repeat this command") + " --full"])
  else . end
