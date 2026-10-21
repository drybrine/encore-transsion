# Copyright (C) 2026 drybrine — Apache-2.0 (see LICENSE)
# Zeroes the cpu / clusterCpu0 / clusterCpu1 / clusterCpu2 attributes of every
# <temp_config> row in Transsion USF's tran_thermal.xml. An all-zero row is
# USF's own "no CPU limit" encoding: its applyCpuLimit() releases the MediaTek
# PowerHAL thermal handle for such a row. Fail-closed: anything it cannot
# rewrite safely aborts without output.
# patch_xml.awk — zero CPU cap attributes inside <temp_config ...> opening tags.
#
# Rewrites ONLY the cpu / clusterCpu0 / clusterCpu1 / clusterCpu2 attribute
# values of temp_config elements to 0, which is Transsion USF's own "no CPU
# limit" encoding (USF applies the all-zero row at cool skin temperatures and
# its applyCpuLimit releases the active PowerHAL thermal handle for it).
# Everything else in the document is byte-preserved.
#
# Hardening (fail-closed):
#   - element names must match temp_config exactly; a longer name such as
#     temp_configExtra is copied verbatim and not counted;
#   - attribute names must be delimited (preceded by start/space/tab/</quote),
#     so bigcpu= or xcpu= are left untouched;
#   - a '>' inside a quoted attribute value is rejected (exit 1, no output),
#     because the first-'>' span cut would silently skip later attributes.
#
# Works on pretty-printed and minified XML (tags may span lines); handles
# double- or single-quoted and space-padded attributes.
# Strict POSIX awk: runs under KernelSU busybox awk and gawk.
#
# Usage:  awk -f patch_xml.awk input.xml > patched.xml
# Status: 0 ok, 1 error (message on stderr; no output is written on error).

BEGIN { buf = ""; err = 0 }
{ buf = buf $0 "\n" }
END {
  out = ""
  rest = buf
  count = 0
  while ((i = index(rest, "<temp_config")) > 0) {
    out = out substr(rest, 1, i - 1)
    span = substr(rest, i)
    j = index(span, ">")
    if (j == 0) {
      print "patch_xml: ERROR: unterminated <temp_config tag" > "/dev/stderr"
      err = 1
      break
    }
    span = substr(span, 1, j)
    rest = substr(rest, i + j)
    # exact element name: the char right after "<temp_config" must be
    # whitespace, '/' (self-closing) or '>' (no attributes)
    nxt = substr(span, 13, 1)
    if (nxt != "" && nxt != " " && nxt != "\t" && nxt != "\n" && nxt != "/" && nxt != ">") {
      out = out span   # different element (e.g. temp_configExtra): keep verbatim
      continue
    }
    if (!span_ok(span)) {
      printf "patch_xml: ERROR: '>' inside a quoted attribute value (temp_config #%d) is not supported\n", count + 1 > "/dev/stderr"
      err = 1
      break
    }
    count++
    span = zero_attr(span, "cpu", "\"")
    span = zero_attr(span, "cpu", "'")
    span = zero_attr(span, "clusterCpu0", "\"")
    span = zero_attr(span, "clusterCpu0", "'")
    span = zero_attr(span, "clusterCpu1", "\"")
    span = zero_attr(span, "clusterCpu1", "'")
    span = zero_attr(span, "clusterCpu2", "\"")
    span = zero_attr(span, "clusterCpu2", "'")
    out = out span
  }
  out = out rest
  if (err == 0 && count == 0) {
    print "patch_xml: ERROR: no <temp_config elements found" > "/dev/stderr"
    err = 1
  }
  if (err == 0) printf "%s", out
  if (err == 1) exit 1
  exit 0
}

# span_ok: the span ends at the first '>'. If a quote is still open there,
# that '>' sat inside a quoted value — the span is truncated mid-attribute.
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

# zero_attr: rewrite name="..." / name='...' to name="0", but only when the
# attribute name is properly delimited (not a suffix of a longer name).
function zero_attr(s, name, q,    out, pos, re, start, ch) {
  out = ""
  pos = 1
  re = name "[ \t]*=[ \t]*" q "[^" q "]*" q
  while (match(substr(s, pos), re)) {
    start = pos + RSTART - 1                       # absolute match start
    if (start == 1) ch = ""                        # name at string start
    else ch = substr(s, start - 1, 1)              # char before the name
    if (ch == "" || ch == " " || ch == "\t" || ch == "<" || ch == "\"" || ch == "'") {
      out = out substr(s, pos, RSTART - 1) name "=\"0\""
    } else {
      out = out substr(s, pos, RSTART - 1) substr(s, start, RLENGTH)
    }
    pos = start + RLENGTH
  }
  return out substr(s, pos)
}
