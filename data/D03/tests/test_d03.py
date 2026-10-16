"""Only model-labelled synthetic text fixtures, never real transcripts."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/d03.py"


def case(case_id="SYN-C01", text="合成测试：坐姿划船三十五公斤十二次"):
    return dict(schema_version=1, case_id=case_id, text=text, source_type="model_generated",
                source_ref="synthetic-unit-test", source_group_id="SYN-G01",
                near_duplicate_group_id="SYN-N01", purpose="dev", dataset_version="semantic-v1",
                revision=1, review_status="draft", categories=["completed_fact"], intents=["record_set"])


class CorpusTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("d03_tested", SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_valid_model_draft_is_not_real_human_or_independent_gold(self):
        result = self.module.validate_cases([case()])
        self.assertTrue(result["valid"])
        self.assertEqual(result["source_counts"]["model_generated"], 1)
        self.assertEqual(result["human_transcript_count"], 0)
        self.assertEqual(result["acceptance"], "development_only_not_frozen")
        self.assertEqual(result["protection"]["status"], "not_supplied")

    def test_source_type_is_explicit_and_review_cannot_be_invented(self):
        for changes in ({"source_type": "real"}, {"review_status": "reviewed"}, {"revision": True}, {"purpose": "heldout"}):
            with self.subTest(changes=changes):
                self.assertFalse(self.module.validate_cases([dict(case(), **changes)])["valid"])

    def test_human_transcript_requires_current_reviewed_d02_provenance(self):
        row = dict(case(), source_type="human_transcript", review_status="reviewed", recording_id="SYN-R01",
                   d02_revision_id="SYN-REV01", segment_index=1, source_sha256="a" * 64,
                   source_ref="D02:SYN-REV01:1", source_group_id="SYN-R01")
        self.assertFalse(self.module.validate_cases([row])["valid"])
        context = {("SYN-R01", "SYN-REV01", 1): {"text": row["text"], "sha256": "a" * 64}}
        result = self.module.validate_cases([row], human_context=context)
        self.assertTrue(result["valid"])
        self.assertEqual(result["human_transcript_count"], 1)
        row["text"] += "不是原话"
        self.assertFalse(self.module.validate_cases([row], human_context=context)["valid"])

    def test_duplicate_id_is_rejected_and_normalized_text_is_reported(self):
        self.assertFalse(self.module.validate_cases([case(), case()])["valid"])
        other = dict(case("SYN-C02"), text="合成测试 坐姿划船三十五公斤十二次！")
        result = self.module.validate_cases([case(), other])
        self.assertTrue(result["valid"])
        self.assertEqual(result["duplicate_candidates"][0]["kind"], "normalized_exact")

    def test_near_duplicates_are_candidates_for_review(self):
        other = dict(case("SYN-C02"), text="合成测试：坐姿划船三十五公斤十三次")
        result = self.module.validate_cases([case(), other])
        self.assertTrue(any(item["kind"] == "near_duplicate" for item in result["duplicate_candidates"]))

    def test_protected_exact_near_or_source_group_overlap_blocks_expansion(self):
        protected = dict(case("SYN-H01"), purpose="heldout", source_group_id="SYN-HG", near_duplicate_group_id="SYN-HN")
        for changes in ({}, {"text": protected["text"].replace("十二", "十三")},
                        {"text": "另一个完全不同的合成计划", "source_group_id": "SYN-HG"},
                        {"text": "另一个完全不同的合成计划", "near_duplicate_group_id": "SYN-HN"}):
            with self.subTest(changes=changes):
                result = self.module.validate_cases([dict(case(), **changes)], protected=[protected])
                self.assertFalse(result["valid"])
                self.assertNotIn(protected["text"], json.dumps(result, ensure_ascii=False))

    def test_missing_fields_empty_text_bad_groups_and_mixed_versions(self):
        bad = case()
        del bad["source_ref"]
        for row in (bad, dict(case(), text=""), dict(case(), categories="completed_fact"),
                    dict(case(), source_group_id="../private"), dict(case(), intents=[])):
            with self.subTest(row=row):
                self.assertFalse(self.module.validate_cases([row])["valid"])
        other = dict(case("SYN-C02", "另一个合成文本"), dataset_version="other")
        self.assertFalse(self.module.validate_cases([case(), other])["valid"])

    def test_empty_corpus_has_no_fake_counts(self):
        result = self.module.validate_cases([], protected=[])
        self.assertTrue(result["valid"])
        self.assertEqual(result["cases"], 0)
        self.assertEqual(result["protection"]["status"], "empty_not_frozen")
        self.assertEqual(result["target_count_range"], [100, 150])

    def test_repeated_malformed_rows_do_not_crash_or_count_as_cases(self):
        bad = dict(case(), case_id=["not-an-id"])
        result = self.module.validate_cases([bad, copy.deepcopy(bad)])
        self.assertFalse(result["valid"])
        self.assertEqual(result["cases"], 0)

    def test_punctuation_only_text_is_not_a_case(self):
        self.assertFalse(self.module.validate_cases([dict(case(), text="。。。！！！")])["valid"])

    def test_same_recording_cannot_hide_behind_different_case_groups(self):
        human = dict(case(), source_type="human_transcript", review_status="reviewed", recording_id="SYN-R01",
                     d02_revision_id="SYN-REV01", segment_index=1, source_sha256="a" * 64,
                     source_ref="D02:SYN-REV01:1", source_group_id="SYN-R01")
        context = {("SYN-R01", "SYN-REV01", 1): {"text": human["text"], "sha256": "a" * 64}}
        protected = dict(human, case_id="SYN-H01", text="完全不同的保护文本", purpose="heldout",
                         source_group_id="OTHER-FAMILY", near_duplicate_group_id="OTHER-NEAR")
        result = self.module.validate_cases([human], protected=[protected], human_context=context)
        self.assertFalse(result["valid"])
        self.assertTrue(any(e["code"] == "protected_source_or_text_overlap" for e in result["errors"]))

    def test_human_protection_checks_identity_and_requires_environment_evidence(self):
        human = dict(case(), source_type="human_transcript", review_status="reviewed", recording_id="SYN-R01",
                     d02_revision_id="SYN-REV01", segment_index=1, source_sha256="a" * 64,
                     source_ref="D02:SYN-REV01:1", source_group_id="SOURCE-FAMILY")
        evidence = {"text": human["text"], "sha256": "a" * 64, "speaker_id_pseudonym": "S01",
                    "session_id": "SESSION01", "environment_id": "ENV01", "source_group_id": "SOURCE-FAMILY"}
        context = {("SYN-R01", "SYN-REV01", 1): evidence}
        protected = dict(human, case_id="SYN-H01", recording_id="SYN-R02", text="保护案例：跑步二十分钟",
                         purpose="heldout", source_group_id="OTHER-FAMILY", near_duplicate_group_id="OTHER-NEAR",
                         speaker_id_pseudonym="S02", session_id="SESSION02", environment_id="ENV02")
        self.assertTrue(self.module.validate_cases([human], protected=[protected], human_context=context)["valid"])
        for field in ("speaker_id_pseudonym", "session_id", "environment_id"):
            with self.subTest(field=field):
                overlap = dict(protected, **{field: evidence[field]})
                self.assertFalse(self.module.validate_cases([human], protected=[overlap], human_context=context)["valid"])
        del evidence["environment_id"]
        self.assertFalse(self.module.validate_cases([human], protected=[protected], human_context=context)["valid"])

    def test_cli_private_input_only_outputs_summary_not_text(self):
        with tempfile.TemporaryDirectory(prefix="d03-synthetic-") as temporary:
            path = Path(temporary) / "cases.jsonl"
            path.write_text(json.dumps(case(), ensure_ascii=False) + "\n", encoding="utf-8")
            process = subprocess.run([sys.executable, "-B", str(SCRIPT), "check", "--input", str(path)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertTrue(json.loads(process.stdout)["valid"])
            self.assertNotIn(case()["text"], process.stdout)
            self.assertNotIn(temporary, process.stdout + process.stderr)


if __name__ == "__main__":
    unittest.main()
