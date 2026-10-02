#!/bin/sh
# accept.sh MODEL : labelled first-person renders of every state, both hands, stitched per hand
cd h
T=64; TH=128; ST=256; SC=32; X=4; Y=8; A=1; B=2
run() { # name btn extra-env...
  n=$1; b=$2; shift 2
  for side in L R; do v=fp2; [ $side = R ] && v=fp2r
    bb=$b; [ $side = R ] && bb=$(echo $b | sed 's/X/A/;s/Y/B/')
    env M=$MODEL VIEW=$v SYN=1 BTN=$(($bb)) EYE=0 Z=0.22 LABEL="$MODEL $side $n" "$@" ./hv >/dev/null; mv eye0.png acc_${side}_$n.png
  done
}
MODEL=$1
run idle 0
run index_touch $T
run trigger_pull $T TRIG=1
run thumbrest $TH
run stick_touch "$ST|$T"
run stick_deflect "$ST|$T" SX=0.8 SY=0.6
run stick_click "$ST|$SC|$T"
run press_X "X|$T"
run press_Y "Y|$T"
run grip_full "$T" SQ=1
run poke 0 POKE=1
for side in L R; do
  ../stitch acc_${MODEL}_${side}_1.png acc_${side}_idle.png acc_${side}_index_touch.png acc_${side}_trigger_pull.png acc_${side}_thumbrest.png
  ../stitch acc_${MODEL}_${side}_2.png acc_${side}_stick_touch.png acc_${side}_stick_deflect.png acc_${side}_stick_click.png acc_${side}_press_X.png
  ../stitch acc_${MODEL}_${side}_3.png acc_${side}_press_Y.png acc_${side}_grip_full.png acc_${side}_poke.png
done
