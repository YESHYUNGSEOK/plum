#!/bin/sh
# Runs inside the terminal under test. Waits for "<work>/go-<name>" holding a
# data file path, sends that file to the terminal, and writes the seconds it
# took to "<work>/result-<name>". The path "quit" ends the loop.
WORK=$1
NAME=$2
: > "$WORK/ready-$NAME"
while :; do
  if [ -f "$WORK/go-$NAME" ]; then
    DATA=$(cat "$WORK/go-$NAME")
    rm -f "$WORK/go-$NAME"
    [ "$DATA" = quit ] && exit 0
    perl -MTime::HiRes=time -e '
      $start = time; system("cat", $ARGV[0]); $elapsed = time - $start;
      open(F, ">", $ARGV[1]); printf F "%.4f\n", $elapsed; close F;' "$DATA" "$WORK/result-$NAME.tmp"
    mv "$WORK/result-$NAME.tmp" "$WORK/result-$NAME"
  else
    sleep 0.02
  fi
done
