#!/bin/bash
# frun.sh — reproduce the Foundation-rewrite regression: 17/17 -> 14/17.
# Runs the 3 failing XG/Xtg cases on the arm9 loader. Needs fpga-xt loader + qemu.
set -e
XTG=~/src/atari/XT/Rocks/xtg
LOADER=~/src/fpga-xt/loader
( cd "$XTG" && make clean >/dev/null 2>&1 && make libXtg.so >/dev/null 2>&1 && make libdemo.so test_alert.so test_clip.so >/dev/null 2>&1 )
for t in libdemo test_alert test_clip; do
  ( cd "$LOADER" && rm -f build-xtg/romfs.bin build-xtg/romfs_blob.h build-xtg/freertos.elf \
     && make BUILD=build-xtg build-xtg/freertos.elf XTC_SO="$XTG/$t.so" >/dev/null 2>&1 )
  echo "=== $t ==="
  printf 'xtcprog\nexit\n' | timeout 120 qemu-system-arm -M xilinx-zynq-a9 -display none \
    -no-reboot -m 1024 -chardev stdio,id=sh0 -semihosting-config enable=on,target=native,chardev=sh0 \
    -kernel "$LOADER/build-xtg/freertos.elf" 2>&1 \
    | grep -vE '^[-*:=. ~+#@%$&]*$' | grep -iE "PASS|FAIL|ABORT|PC=|DFAR|clicks=" | head -4
done
