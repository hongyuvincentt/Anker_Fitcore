# D05 offline evaluation

Python 3.9+ standard library; no installation, network, paid-model calls or changes to HTTP/mobile/backend interfaces. The JSONL format is a task-local companion record of already observed facts and decisions; it is **not** an HTTP DTO or a new system logging API.

Current real evaluation count: **0**. Real accuracy, latency, model cost and independent held-out acceptance are **UNMEASURED/UNVERIFIED**. Tests create temporary, explicitly synthetic records only. No private recordings, transcripts, gold, consent rows or billing evidence ship here.

From the extracted D05 directory, create an empty local report in a new location:

```sh
python3 -m unittest discover -s tests -v
```

Use the following reproducible empty-workspace flow (POSIX shell):

```sh
WORK=$(mktemp -d)
chmod 700 "$WORK"
cp templates/CASES.jsonl "$WORK/cases.jsonl"
cp templates/RUN.json "$WORK/run.json"
python3 scripts/d05.py evaluate --input "$WORK/cases.jsonl" --manifest "$WORK/run.json" --output "$WORK/report"
```

All metrics in that report are unmeasured, with no measured zero rate, zero latency or zero total cost. `--output` must name a new directory and never overwrites previous artifacts. It creates report.json (authoritative numerators/denominators/version metadata), EVAL_RESULTS.csv (original columns), and report.md. The original CSV template is copied byte-for-byte from the task package. Keep input/output under private local permissions: output directory is created mode 0700; files inherit the caller's umask. Do not put actual logs in Git/ZIP.

For an actual operator-prepared run, replace the empty manifest with:

```json
{
  "schema_version": "d05.input.v1",
  "evaluation_time": "ISO8601_TIMESTAMP_WITH_TIMEZONE",
  "runs": {
    "YOUR_RUN_VERSION_REF": {
      "source_commit": "FULL_ACTUAL_GIT_COMMIT_SHA",
      "dataset_version": "YOUR_IMMUTABLE_DATASET_AND_LABEL_VERSION",
      "model_provider": "YOUR_PROVIDER_OR_none",
      "model_version": "YOUR_PINNED_MODEL_OR_not_used",
      "schema_version": "d05.input.v1",
      "environment": {"python": "ACTUAL_VERSION", "platform": "ACTUAL_PLATFORM"},
      "mode": "real_audio",
      "split": "exploratory",
      "reviewer": "ANONYMOUS_REVIEWER_OR_PENDING"
    }
  }
}
```

This is field documentation, not a populated data template. Fill it from actual evidence. `source_commit` must resolve to that exact full commit in --source-repo for every non-synthetic group; nonexistent SHAs and missing repositories block evaluation. Synthetic-only fixtures may use `synthetic:fixture-id`, only with mode=synthetic and source=synthetic_fixture. Nonempty runs require a timezone-aware evaluation_time. All cases bind version_ref; unknown versions are rejected. Runs pin provider, model, schema, dataset and environment. Use immutable identifiers and precise model versions, not rolling aliases. The evaluator checks local commit existence and required strings; it cannot establish that an operator's model/dataset declaration is truthful.

```sh
python3 scripts/d05.py evaluate --input PRIVATE_CASES.jsonl --manifest PRIVATE_RUN.json --source-repo LOCAL_SOURCE_CHECKOUT --evidence-root PRIVATE_COST_EVIDENCE --d04-audit PRIVATE_D04_AUDIT.json --output NEW_PRIVATE_REPORT
```

`--evidence-root` is needed only for non-synthetic verified costs; --d04-audit is optional context whose SHA256 is recorded. A supplied audit never grants independent acceptance: current consent, source/label hashes, exposure history, provenance, independent freeze approval and source artifacts need separate checks. Actual reports remain `exploratory_not_independent`. Approval of report publicity stays with the responsible human.

Each nonblank JSONL line is one utterance/case with the required keys below. Do not copy this table into live HTTP requests. See `docs/INPUT.schema.json` and `docs/RUN.schema.json`; runtime validation additionally enforces cross-field semantics.

| Field | Meaning |
| --- | --- |
| schema_version | Exactly d05.input.v1 |
| case_id | Unique anonymous utterance/case ID in the entire input; duplicates rejected |
| recording_id | Anonymous source recording ID; several distinct utterances may share a recording |
| version_ref | Key in manifest.runs |
| mode | synthetic, text_simulation, replay, real_audio |
| source | synthetic_fixture, human_written, model_generated, human_audio, recorded_replay |
| gold_status | reviewed, unreviewed, disputed; only reviewed gold is scored |
| expected_facts | Array of {fact_id,fact}; stable IDs unique within utterance |
| actual | Array of decisions; COMMIT={decision,origin,fact_id,fact}; DEFER/REJECT={decision,origin}; origin=auto/manual |
| adjudication | {status:unreviewed} by default; reviewed requires reviewer_id, optional boolean/null layer flags |
| slices | Required anonymous strings: device,speaker,noise,action,numeric_ambiguity; use UNKNOWN if unavailable |
| latency | Optional/null; {ms:finite_nonnegative_number,evidence_ref:local_trace_reference} |
| cost | Optional/null; {status:verified/unverified,amount:decimal_string,currency:uppercase_3letter,evidence_ref:reference,evidence_sha256:SHA256}; non-synthetic verified costs require all fields and local matching file |

Fact always has **all** fields: exercise (string/null), weight_kg (nonnegative number/null), reps (nonnegative integer/null), temporal_modality (completed/historical/planned/unknown/null), time (structured JSON/null), target (structured JSON/null). Completed facts require exercise. Null numeric fields mean explicitly not applicable, not an unknown gold value: unknown or disputed values keep gold_status unreviewed/disputed. Numeric weight_kg compares numerically, so 20 and 20.0 agree; bools are rejected. Reps 8.0 is invalid rather than silently converted to 8. Other fields retain exact JSON type/value matching. Do not apply unit conversion, alias normalisation or an LLM inside this tool. Gold and actual must already use the same agreed schema and units.

Use a stable fact_id for the same accounting object across corrections. A correction case's expected_facts contains the **final corrected snapshot** (same fact_id, corrected fields), and actual contains automatic decisions produced by that utterance, without an operator's later confirmation. A correction target is represented explicitly in fact.target, e.g. {"fact_id":"prior-set-id"}; time and target compare exactly as supplied. A gold/actual mismatch of identity, target or any structured field is wrong. If system logs lack a stable ID or target, the operator needs an audited mapping before evaluation; do not invent one from fuzzy text. No prior-state or cross-utterance correction inference is performed. Do not repeat pre-existing facts as if this utterance newly committed them. Actual duplicate COMMITs intentionally remain duplicates.

Mixed modes or version_ref values fail by default. `--group-report` allows a report with separate group rows and **no pooled result**. Never claim a text simulation or replay is real audio acceptance. Never claim a development-exposed set is independent held-out. An anonymous recording/case can occur only once per evaluated utterance; assigning a new case ID to duplicate source evidence is invalid preparation.

Reviewed gold requires every expected fact's temporal_modality to be completed, historical or planned. An unknown/null modality is rejected even if another fact is correct; retain gold_status=unreviewed/disputed until resolved. Those statuses visibly exclude the entire utterance from fact metrics. Explicit historical/planned facts remain valid resolved gold, outside the completed-fact denominator.

Layer flags are asr_transcription_error, asr_numeric_error, semantic_error, fact_engine_error. Missing/null means unknown; reviewed false is a measured negative. The tool never infers ASR errors from missing ASR text or fact mismatches. Human review/eligibility is declared input; the evaluator cannot create human listening, dual review or consent evidence.

Callable interface:

```python
evaluate(records, manifest, group_report=False, d04_audit=None,
         source_repo=None, evidence_root=None) -> dict
```

It raises ValueError for invalid schema, duplicate case/gold IDs, invalid/nonfinite/negative numbers, mixed groups without opt-in, bad local source commit or mismatched cost evidence. CLI exits 2 on validation failure. JSON duplicate keys and NaN/Infinity are rejected. Output stores source/input/manifest versions, evaluator script SHA256, actual Python runtime and input byte hashes; it omits raw facts/transcripts and supplied audit contents, but identifiers, labels and evidence refs can still be sensitive. Keep all actual artifacts private and review before sharing.

Definitions: `docs/METRICS.md`, `docs/ERROR_CATEGORIES.md`. Report starter: `templates/REPORT.md`. Verification record: `docs/VERIFICATION.md`.
