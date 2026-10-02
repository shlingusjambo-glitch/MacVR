Offline hand/controller fitting + render harness for mac/Sources/Hands.swift (dev only, not shipped).

Build (from this folder):
  mkdir -p h && ln -sfn ../../../mac/Resources/controllers h/controllers && ln -sfn ../../../mac/Resources/hands h/hands
  swiftc -O -import-objc-header ../../common/vr4mac.h -o h/hv main.swift render.swift probe.swift eye.swift fit.swift meshdata.swift perf.swift ../../mac/Sources/ControllerGLB.swift ../../mac/Sources/ControllerModels.swift ../../mac/Sources/Hands.swift
  swiftc -O -o stitch stitch.swift
Run from h/ (needs ../track.bin):
  FIT=1 ./hv                 refit HandModel.place for quest1/2/3 (prints Swift literals)
  SCORE=1 ./hv               score current placements, per thumb target distances
  M=q1|q2|q3 SYN=1 EYE=0 VIEW=fp2|fp2r|side|side_r|inner|front|under|under_r|top|trig|face|face_r BTN=<bits> TRIG=0..1 SQ=0..1 SX SY POKE=1 MARK=1 LABEL=.. Z=<fov half tan> ./hv   -> eye0.png
  HAND_DEBUG_COLORS=1        one colour per finger;  MARK=1 red targets, green index pad, cyan thumb pad
  ../accept.sh q1            labelled state strips (acc_*.png)
  PERF=1 ./hv                ms/frame with and without subdivision
