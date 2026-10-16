# D05 error categories

| Category | Recorded when | What it does not establish |
| --- | --- | --- |
| WRONG_COMMIT | An automatic COMMIT cannot match an unused exact reviewed completed fact | Which upstream layer caused the wrong COMMIT |
| MISSED_COMPLETED_FACT | A reviewed completed fact has no correct automatic match | Whether ASR, semantic parsing or Fact Engine caused it |
| PENDING | At least one automatic DEFER in an utterance | A causal error or an incorrect COMMIT |
| ASR_TRANSCRIPTION | A human explicitly adjudicates the ASR transcription error flag | Numeric error unless that separate flag was reviewed |
| ASR_NUMERIC | A human explicitly adjudicates a numeric ASR error | A semantic or accounting error by inference |
| SEMANTIC | A human explicitly adjudicates semantic parsing error | That ASR was correct or incorrect |
| FACT_ENGINE | A human explicitly adjudicates Fact Engine error | That other layers were correct |
| UNKNOWN | Missing/null error flag, unreviewed/disputed gold, or unavailable observation | False, zero, or a reviewed negative |

Only explicit flags with adjudication.status=reviewed and reviewer_id are scored. Missing ASR text is not an error. The input intentionally has no transcript field. Record private listening/reference/ASR evidence separately under D02 policy; use anonymous IDs to find it. The evaluator validates declarations, cannot perform a human review, and never supplies review signatures.

Failure archives in report.json contain case_id/recording_id, slice labels (device, pseudonymous speaker, noise, action, numeric_ambiguity), counts and explicit error flags. They omit facts, transcripts and raw audit content. Slice labels must be anonymous and use UNKNOWN when unknown. An empty slice field is rejected rather than silently grouped under an invented value. This is traceable triage, not proof of failure causality.
