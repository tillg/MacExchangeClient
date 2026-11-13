#!/bin/zsh
# Builds the R5F view harness from the app's views (all of Sources/MailReplica but MailReplicaApp.swift) and runs one
# scenario with sample data. Needs the debug app built first (its MailModel/EWS objects and modules).
# usage: specs/bugs/probes-views/run-harness.sh build | <scenario>
set -e
W="${0:A:h}/../../.."
OUT="$W/tmp/R5FHarness"
if [ "$1" = build ]; then
  mkdir -p "$W/tmp"
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  swiftc -sdk $SDK -target arm64-apple-macosx14.0 -parse-as-library -Onone -g \
    -I "$W/.build/debug" -module-name MailReplica \
    $(ls "$W"/Sources/MailReplica/*.swift | grep -v MailReplicaApp.swift) "${0:A:h}/R5FHarness.swift" \
    "$W/.build/debug/MailModel.o" "$W/.build/debug/EWS.o" -lsqlite3 -o "$OUT"
  exit 0
fi
env MAIL_SAMPLE_DATA=1 R5F_SCENARIO="$1" "$OUT"
