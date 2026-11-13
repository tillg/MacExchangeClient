#!/bin/zsh
# Safe UI snapshot: sample data only, never the real account.
# usage: tools/snapshot.sh out.png [VAR=val ...]   e.g. MAIL_SNAPSHOT_DARK=1
# The app's own defaults domain may hold a real Exchange account; a copy of the binary under another
# name gets its own (empty) defaults domain, and MAIL_SAMPLE_DATA=1 forces sample data.
set -e
D="${0:A:h}/../.build/debug"
cmp -s "$D/MailReplica" "$D/MailReplicaSnapshot" 2>/dev/null || { rm -f "$D/MailReplicaSnapshot"; cp "$D/MailReplica" "$D/MailReplicaSnapshot"; }
out=$1; shift
env MAIL_SAMPLE_DATA=1 MAIL_SNAPSHOT="$out" "$@" "$D/MailReplicaSnapshot"
