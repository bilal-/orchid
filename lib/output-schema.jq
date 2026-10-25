# The supported output-contract schema vocabulary is deliberately finite.
# These definitions consume data; no contract value is evaluated as jq code.
def oc_keys($allowed): ((keys_unsorted - $allowed) | length) == 0;
def oc_natural: type == "number" and isfinite and . >= 0 and floor == .;
def oc_bounded_json($depth):
  if $depth > 16 then false
  elif type == "object" then all(.[]; oc_bounded_json($depth + 1))
  elif type == "array" then all(.[]; oc_bounded_json($depth + 1))
  else true end;

def oc_schema_valid($depth):
  type == "object" and $depth <= 16 and
  oc_keys(["type", "required", "properties", "additionalProperties", "items",
           "enum", "const", "minLength", "maxLength", "minItems", "maxItems",
           "minimum", "maximum"]) and
  (if has("type") then (.type | IN("object", "array", "string", "number", "integer", "boolean", "null")) else true end) and
  (if has("required") then (.required | type == "array" and all(.[]; type == "string") and (unique | length) == length) else true end) and
  (if has("properties") then (.properties | type == "object" and all(.[]; oc_schema_valid($depth + 1))) else true end) and
  (if has("additionalProperties") then (.additionalProperties | type == "boolean") else true end) and
  (if has("items") then (.items | oc_schema_valid($depth + 1)) else true end) and
  (if has("enum") then (.enum | type == "array" and length > 0 and all(.[]; oc_bounded_json(0)) and (unique | length) == length) else true end) and
  (if has("const") then (.const | oc_bounded_json(0)) else true end) and
  (if has("minLength") then (.minLength | oc_natural) else true end) and
  (if has("maxLength") then (.maxLength | oc_natural) else true end) and
  (if has("minItems") then (.minItems | oc_natural) else true end) and
  (if has("maxItems") then (.maxItems | oc_natural) else true end) and
  (if has("minimum") then (.minimum | type == "number" and isfinite) else true end) and
  (if has("maximum") then (.maximum | type == "number" and isfinite) else true end) and
  (if has("minLength") and has("maxLength") then .minLength <= .maxLength else true end) and
  (if has("minItems") and has("maxItems") then .minItems <= .maxItems else true end) and
  (if has("minimum") and has("maximum") then .minimum <= .maximum else true end);

def oc_type_matches($wanted):
  if $wanted == "integer" then type == "number" and isfinite and floor == .
  else type == $wanted end;

def oc_schema_matches($schema):
  . as $value |
  (if type == "number" then isfinite else true end) and
  (if $schema | has("type") then oc_type_matches($schema.type) else true end) and
  (if $schema | has("enum") then any($schema.enum[]; . == $value) else true end) and
  (if $schema | has("const") then . == $schema.const else true end) and
  (if type == "object" then
     all(($schema.required // [])[]; . as $key | $value | has($key)) and
     all(($schema.properties // {} | to_entries)[]; . as $entry |
       (($value | has($entry.key)) | not) or ($value[$entry.key] | oc_schema_matches($entry.value))) and
     (if $schema.additionalProperties == false then
        ((keys_unsorted - ($schema.properties // {} | keys_unsorted)) | length) == 0
      else true end)
   else true end) and
  (if type == "array" then
     (if $schema | has("items") then all(.[]; oc_schema_matches($schema.items)) else true end) and
     (if $schema | has("minItems") then length >= $schema.minItems else true end) and
     (if $schema | has("maxItems") then length <= $schema.maxItems else true end)
   else true end) and
  (if type == "string" then
     (if $schema | has("minLength") then length >= $schema.minLength else true end) and
     (if $schema | has("maxLength") then length <= $schema.maxLength else true end)
   else true end) and
  (if type == "number" then
     (if $schema | has("minimum") then . >= $schema.minimum else true end) and
     (if $schema | has("maximum") then . <= $schema.maximum else true end)
   else true end);

def oc_path_valid:
  type == "string" and length > 0 and
  (startswith("/") | not) and (test("^[A-Za-z]:") | not) and
  (contains("\\") | not) and (test("[\u0000-\u001f\u007f]") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".." and
     (ascii_downcase != ".git") and (ascii_downcase != ".orchid")));

def oc_artifact_valid:
  type == "object" and oc_keys(["path", "schema", "min_bytes", "max_bytes", "contains"]) and
  has("path") and (.path | oc_path_valid) and
  (if has("schema") then (.schema | oc_schema_valid(0)) else true end) and
  (if has("min_bytes") then (.min_bytes | oc_natural and . <= 1048576) else true end) and
  (if has("max_bytes") then (.max_bytes | oc_natural and . <= 1048576) else true end) and
  ((.min_bytes // 0) <= (.max_bytes // 1048576)) and
  (if has("contains") then (.contains | type == "array" and length <= 32 and
     all(.[]; type == "string" and length > 0 and (test("[\u0000-\u001f\u007f]") | not))) else true end);

def oc_contract_valid:
  type == "object" and oc_keys(["contract", "operations", "envelope_schema", "artifacts"]) and
  .contract == 1 and
  (if has("operations") then (.operations | type == "array" and length > 0 and length <= 5 and
     all(.[]; IN("implement", "review", "critique", "orchestrate", "hook")) and
     (unique | length) == length) else true end) and
  (if has("envelope_schema") then (.envelope_schema | oc_schema_valid(0)) else true end) and
  (if has("artifacts") then (.artifacts | type == "array" and length <= 32 and
     all(.[]; oc_artifact_valid) and (map(.path) | unique | length) == length) else true end);
