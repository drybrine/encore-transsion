# Copyright (C) 2026 drybrine — Apache-2.0 (see LICENSE)
# Zeroes the cpu / clusterCpu0 / clusterCpu1 / clusterCpu2 attributes of every
# <temp_config> row in Transsion USF's tran_thermal.xml. An all-zero row is
# USF's own "no CPU limit" encoding: its applyCpuLimit() releases the MediaTek
# PowerHAL thermal handle for such a row. Fail-closed: anything it cannot
# rewrite safely aborts without output.
# verify_xml.awk — safety gate for a patched tran_thermal.xml.
#
# Fails (status 1) if:
#   - any <temp_config ...> opening tag still carries a nonzero
#     cpu / clusterCpu0 / clusterCpu1 / clusterCpu2 value (double- or
#     single-quoted), counting only exact temp_config element names;
#   - a temp_config tag is unterminated, or contains '>' inside a quoted
#     attribute value;
#   - no temp_config element exists.
#
# Usage:  awk -f verify_xml.awk patched.xml
# Status: 0 all CPU cap values are zero, 1 error (message on stderr).

BEGIN { buf = ""; bad = 0; count = 0 }
{ buf = buf $0 "\n" }
END {
  rest = buf
  while ((i = index(rest, "<temp_config")) > 0) {
    span = substr(rest, i)
    j = index(span, ">")
    if (j == 0) {
      print "verify_xml: ERROR: unterminated <temp_config tag" > "/dev/stderr"
      bad = 1
      break
    }
    span = substr(span, 1, j)
    rest = substr(rest, i + j)
    nxt = substr(span, 13, 1)
    if (nxt != "" && nxt != " " && nxt != "\t" && nxt != "\n" && nxt != "/" && nxt != ">") {
      continue   # different element (e.g. temp_configExtra): not ours
    }
    if (!span_ok(span)) {
      printf "verify_xml: ERROR: '>' inside a quoted attribute value (temp_config #%d)\n", count + 1 > "/dev/stderr"
      bad = 1
      continue
    }
    count++
    bad = (attr_val(span, "cpu", "\"") != 0 || attr_val(span, "cpu", "'") != 0)
    for (ci = 0; ci <= 7; ci++) {
      if (attr_val(span, "clusterCpu" ci, "\"") != 0) bad = 1
      if (attr_val(span, "clusterCpu" ci, "'") != 0) bad = 1
    }
    # Any other cluster index must also be clear - the patcher only handles 0..7,
    # so a leftover here means the device caps a cluster we do not know about.
    if (match(span, /clusterCpu[0-9]+ *= *["\x27][1-9]/)) bad = 1
    if (bad) {
      printf "verify_xml: ERROR: temp_config #%d still has a nonzero CPU cap value\n", count > "/dev/stderr"
      bad = 1
    }
  }
  if (count == 0) {
    print "verify_xml: ERROR: no <temp_config elements found" > "/dev/stderr"
    bad = 1
  }
  if (bad == 1) exit 1
  exit 0
}

function span_ok(s,    i, n, c, q) {
  q = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q == "") {
      if (c == "\"" || c == "'") q = c
    } else if (c == q) {
      q = ""
    }
  }
  return q == ""
}

# attr_val: value of the delimited attribute `name` quoted with `q`, 0 if
# absent (or only present as a suffix of a longer attribute name).
function attr_val(span, name, q,    re, m, pos, start, ch) {
  pos = 1
  re = name "[ \t]*=[ \t]*" q "[^" q "]*" q
  while (match(substr(span, pos), re)) {
    start = pos + RSTART - 1
    if (start == 1) ch = ""
    else ch = substr(span, start - 1, 1)
    if (ch == "" || ch == " " || ch == "\t" || ch == "<" || ch == "\"" || ch == "'") {
      m = substr(span, start, RLENGTH)
      sub("^[^=]*=[ \t]*" q, "", m)
      sub(q "$", "", m)
      return m + 0
    }
    pos = start + RLENGTH
  }
  return 0
}
