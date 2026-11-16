# Helpers shared by the showcase scripts. Sourced, not executed.

# awk functions that turn text into a JSON string literal: quotes, backslashes and control
# characters are escaped. Run text through `utf8` first; JSON parsers reject invalid UTF-8.
JSON_AWK='
function json_init(   i) {
    for (i = 1; i < 32; i++) JSON_ESCAPE[sprintf("%c", i)] = sprintf("\\u%04x", i)
    JSON_ESCAPE[sprintf("%c", 127)] = "\\u007f"
    JSON_ESCAPE["\""] = "\\\""
    JSON_ESCAPE["\\"] = "\\\\"
}
function json(s,   out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        out = out ((c in JSON_ESCAPE) ? JSON_ESCAPE[c] : c)
    }
    return "\"" out "\""
}
'

# Drops byte sequences that are not valid UTF-8.
utf8() {
    iconv -c -f UTF-8 -t UTF-8
}

# json_string TEXT: prints TEXT as a JSON string literal.
json_string() {
    printf '%s' "$1" | utf8 | LC_ALL=C awk "$JSON_AWK"'
        BEGIN { json_init(); ORS = "" }
        { text = (NR > 1) ? text "\n" $0 : $0 }
        END { print json(text) }'
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

# require_number VALUE MIN MAX NAME: fails unless VALUE is a decimal number between MIN and MAX.
require_number() {
    if ! LC_ALL=C awk 'BEGIN {
        v = ARGV[1]
        exit !(v ~ /^-?[0-9]+([.][0-9]+)?$/ && v + 0 >= ARGV[2] + 0 && v + 0 <= ARGV[3] + 0)
    }' "$1" "$2" "$3"; then
        fail "$4: ожидается число от $2 до $3, получено «$1»"
    fi
}
