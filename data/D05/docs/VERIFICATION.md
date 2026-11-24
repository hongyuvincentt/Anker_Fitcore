# D05 verification record

All test facts, identifiers, review flags, costs and timings are temporary synthetic calculation fixtures. No real model/provider/audio/system evaluation occurred. Real count is 0; all real performance measures are unmeasured. Python in this workspace: 3.12; source targets standard-library Python 3.9+.

1. Before d05.py existed: `python3 -m unittest discover -s data/D05/tests -q` ran 32 test methods and failed with 35 assertions (subtests included), expected missing-evaluator/CLI behavior. The invalid-JSON CLI test was tightened before implementation to require its actual duplicate-key diagnostic; it could not pass merely because the script was absent.
2. Implemented evaluator: same command ran 32 tests, all passed.
3. Added exclusion status, incomplete completed gold, actual cost-evidence integrity, audit distrust, empty public manifest and no-overwrite regressions: 39 test methods; expected red had 4 failures. A missing-function assertion replaced the initial AttributeError before implementation.
4. Implemented focused changes: 39 test methods, all passed.
5. Edge regressions for malformed enums, null actual cost and boolean-vs-number target matching: 42 test methods; expected red had one failure plus four TypeError/AttributeError errors identifying the missing validation; focused fix gave 42 passing methods.
6. Numeric weight equivalence and evaluator/runtime pinning: 45 test methods; after tightening the missing-key assertion, expected red had two assertion failures. Added numeric weight comparison (other JSON fields remain exact) plus script SHA256/runtime metadata: 45 methods passed.
7. Independent review found that unknown/null temporal modality in reviewed gold could silently disappear from the completed-fact denominator. Added unresolved-reviewed rejection plus unreviewed-exclusion and resolved historical/planned regressions: 48 test methods, expected red with two assertion failures. Rejecting invalid reviewed gold metadata gives 48 passing methods.

Independent hand-calculated fixtures: two expected completed facts, one exact auto match plus one extra => correct_auto_commit=1/2, wrong_commit=1/2, missed_fact=1/2. Duplicate exact auto COMMIT for one gold => correct=1/1, wrong=1/2, missed=0/1. Nearest-rank latency [1,2,3,4,100] => P50=3ms/P95=100ms at n=5. Verified decimal costs 0.10+0.20 USD => 0.30 USD; one verified zero plus a missing row => total=null, partial subtotal=0.

No automatic freeze approval, independent held-out evidence, real accuracy, real delay or independently verified billing claims result from these tests. D04 audit is read-only context only. Root owns integrated checks, packaging, commit/remote/PR delivery.
