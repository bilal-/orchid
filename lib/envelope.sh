#!/usr/bin/env bash
envelope_validate() {
  jq -e '
    (.contract == 1)
    and (.job_id | type == "string" and length > 0)
    and (.task   | type == "string" and length > 0)
    and (.status | IN("ok","failed","rate_limited","timeout","auth","malformed"))
    and (
      .status != "ok" or (
        (.operation == "implement" and (.summary | type == "string" and length > 0))
        or ((.operation | IN("review","critique"))
            and (.verdict | IN("approve","request-changes"))
            and (.scope_complete | type == "boolean"))
        or (.operation == "orchestrate"
            and (.actions | type == "array" and all(.[]; type == "string"))
            and (.summary | type == "string" and length > 0))
      )
    )
    and (
      (has("findings") | not) or
      (.findings | type == "array" and
        all(.[];
          type == "object"
          and (.severity | type == "string" and length > 0)
          and (.title    | type == "string" and length > 0)))
    )
    and (
      (has("commits") | not) or
      (.commits | type == "array" and all(.[]; type == "string"))
    )
  ' "$1" >/dev/null
}
envelope_field() { jq -r "$2" "$1"; }
