"""Offline integration tests; every audio fixture is synthetic and temporary."""
import csv
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import wave


BASE = Path(__file__).resolve().parents[1]
SCRIPT = BASE / "scripts" / "d01.py"
CONSENT = "consent_id,speaker_id_pseudonym,consent_timestamp,recording_allowed,internal_team_use_allowed,aws_model_processing_allowed,share_scope,retention_until,withdrawal_method,consent_status,withdrawn_at,verification_reviewer,notes_no_pii".split(",")
MANIFEST = "recording_id,speaker_id_pseudonym,consent_id,session_id,scene_id,recorded_at,device_type,recording_source,sample_rate_hz,channels,bits_per_sample,duration_sec,size_bytes,sha256,private_storage_pointer,quality_status,label_status,data_split,retention_status".split(",")


class CollectionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="d01-synthetic-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "private"
        # Independent empty store setup allows negative tests to reach their boundary.
        self.root.mkdir(mode=0o700)
        (self.root / "audio").mkdir(mode=0o700)
        self.write_csv("CONSENT_REGISTER.csv", CONSENT, [])
        self.write_csv("WAV_MANIFEST.csv", MANIFEST, [])
        self.wav = self.base / "synthetic.wav"
        self.make_wav(self.wav)

    def make_wav(self, path, rate=16000, channels=1, width=2, silent=False, seconds=0.2):
        with wave.open(str(path), "wb") as out:
            out.setparams((channels, width, rate, 0, "NONE", "not compressed"))
            if width == 2:
                frames = b"".join(struct.pack("<h", 0 if silent else int(8000 * math.sin(i * .17))) * channels for i in range(int(rate * seconds)))
            else:
                frames = bytes([128]) * int(rate * seconds * channels * width)
            out.writeframes(frames)

    def write_csv(self, name, fields, rows):
        with (self.root / name).open("w", encoding="utf-8-sig", newline="") as out:
            writer = csv.DictWriter(out, fieldnames=fields)
            writer.writeheader()
            writer.writerows(rows)

    def rows(self, name):
        with (self.root / name).open(encoding="utf-8-sig", newline="") as inp:
            return list(csv.DictReader(inp))

    def grant(self, **changes):
        # This consent is fabricated solely for a temporary synthetic test fixture.
        row = dict.fromkeys(CONSENT, "")
        row.update(consent_id="TEST-C01", speaker_id_pseudonym="TEST-S01", consent_timestamp="2026-10-01T10:00:00+08:00", recording_allowed="true", internal_team_use_allowed="false", aws_model_processing_allowed="false", retention_until="2026-10-31", withdrawal_method="test-contact", consent_status="granted", verification_reviewer="TEST-REVIEWER")
        row.update(changes)
        self.write_csv("CONSENT_REGISTER.csv", CONSENT, [row])

    def call(self, command, *args, ok=True):
        process = subprocess.run([sys.executable, "-B", str(SCRIPT), command, "--root", str(self.root), "--as-of", "2026-10-16", *map(str, args)], text=True, capture_output=True)
        self.assertEqual(process.returncode, 0 if ok else 2, process.stdout + process.stderr)
        try:
            payload = json.loads(process.stdout if ok else process.stderr)
        except json.JSONDecodeError:
            self.fail("CLI has not implemented the JSON result/error contract: " + process.stderr)
        return payload

    def import_audio(self, *args, ok=True):
        return self.call("import", "--wav", self.wav, "--recording-id", "TEST-R01", "--consent-id", "TEST-C01", "--speaker-id", "TEST-S01", "--session-id", "TEST-SESSION", "--scene-id", "ordinary", "--recorded-at", "2026-10-16T10:00:00+08:00", "--device-type", "iphone", *args, ok=ok)

    def test_init_empty_templates_and_no_overwrite(self):
        self.root = self.base / "new-private"
        self.call("init")
        self.assertEqual(self.rows("CONSENT_REGISTER.csv"), [])
        self.assertEqual(self.rows("WAV_MANIFEST.csv"), [])
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertIn("exists", self.call("init", ok=False)["error"])

    def test_no_consent_is_never_auto_granted(self):
        self.assertIn("consent", self.import_audio(ok=False)["error"])
        self.assertEqual(self.rows("CONSENT_REGISTER.csv"), [])
        self.assertEqual(list((self.root / "audio").iterdir()), [])

    def test_local_import_preserves_original_and_does_not_grant_cloud(self):
        self.grant()
        original = self.wav.read_bytes()
        result = self.import_audio("--recording-source", "iphone_microphone")
        self.assertEqual(result["recording"]["quality_status"], "needs_review")
        row = self.rows("WAV_MANIFEST.csv")[0]
        self.assertEqual(row["sha256"], hashlib.sha256(original).hexdigest())
        self.assertEqual(row["private_storage_pointer"], "audio/TEST-R01.wav")
        self.assertEqual(self.wav.read_bytes(), original)
        self.assertEqual((self.root / row["private_storage_pointer"]).read_bytes(), original)
        self.assertEqual(self.call("eligible", "--purpose", "cloud")["eligible"], [])

    def test_unknown_source_not_counted_as_human(self):
        self.grant()
        self.import_audio()
        report = self.call("report")
        self.assertEqual(report["human_verified_recordings"], 0)
        self.assertEqual(report["actual_people"], 0)
        self.assertEqual(report["pending_review_recordings"], 1)
        self.assertEqual(report["acceptance"], "not_accepted")

    def test_manual_human_review_and_separate_purposes(self):
        self.grant()
        self.import_audio("--recording-source", "iphone_microphone")
        self.call("verify-human", "--recording-id", "TEST-R01", "--reviewer", "TEST-JZD")
        self.assertEqual(len(self.call("eligible", "--purpose", "local")["eligible"]), 1)
        self.assertEqual(self.call("eligible", "--purpose", "team")["eligible"], [])
        self.assertEqual(self.call("eligible", "--purpose", "cloud")["eligible"], [])
        self.grant(internal_team_use_allowed="true", aws_model_processing_allowed="true")
        self.assertEqual(len(self.call("eligible", "--purpose", "cloud")["eligible"]), 1)
        self.assertEqual(self.call("report")["actual_people"], 1)

    def test_recording_denied_and_speaker_mismatch(self):
        self.grant(recording_allowed="false")
        self.assertIn("recording_allowed", self.import_audio(ok=False)["error"])
        self.grant(speaker_id_pseudonym="OTHER")
        self.assertIn("speaker", self.import_audio(ok=False)["error"])

    def test_pending_revoked_and_expired_consent_block_import(self):
        for changes in ({"consent_status": "pending"}, {"withdrawn_at": "2026-10-15T11:00:00+08:00"}, {"retention_until": "2026-10-15"}, {"retention_until": "2026-10-16T00:00:00+08:00"}):
            with self.subTest(changes=changes):
                self.grant(**changes)
                self.assertIn("consent", self.import_audio(ok=False)["error"])

    def test_withdrawal_and_expiry_excluded_retroactively(self):
        self.grant()
        self.import_audio("--recording-source", "iphone_microphone")
        self.call("verify-human", "--recording-id", "TEST-R01", "--reviewer", "TEST-JZD")
        self.grant(retention_until="2026-10-15")
        self.assertEqual(self.call("eligible", "--purpose", "local")["eligible"], [])
        self.grant()
        self.call("withdraw", "--consent-id", "TEST-C01", "--withdrawn-at", "2026-10-16T11:00:00+08:00")
        self.assertEqual(self.call("eligible", "--purpose", "local")["eligible"], [])
        self.assertEqual(self.rows("CONSENT_REGISTER.csv")[0]["consent_status"], "withdrawn")
        self.assertTrue((self.root / "audio/TEST-R01.wav").exists())

    def test_format_and_silence_rejected(self):
        self.grant()
        for kwargs, expected in (({"rate": 8000}, "16000"), ({"channels": 2}, "mono"), ({"width": 1}, "PCM16"), ({"silent": True}, "silence"), ({"seconds": 0}, "empty")):
            with self.subTest(kwargs=kwargs):
                self.make_wav(self.wav, **kwargs)
                self.assertIn(expected, self.import_audio(ok=False)["error"])
        self.wav.write_bytes(b"not WAV")
        self.assertIn("RIFF", self.import_audio(ok=False)["error"])

    def test_truncated_size_and_riff_length_rejected(self):
        self.grant()
        original = self.wav.read_bytes()
        self.wav.write_bytes(original[:-2])
        self.assertIn("RIFF", self.import_audio(ok=False)["error"])
        self.wav.write_bytes(original + b"trailing")
        self.assertIn("RIFF", self.import_audio(ok=False)["error"])
        with self.wav.open("wb") as out:
            out.truncate(7_000_001)
        self.assertIn("7MB", self.import_audio(ok=False)["error"])

    def test_duplicate_hash_id_and_destination_never_overwritten(self):
        self.grant()
        self.import_audio()
        existing = (self.root / "audio/TEST-R01.wav").read_bytes()
        self.assertIn("duplicate", self.import_audio(ok=False)["error"])
        self.assertIn("duplicate", self.import_audio("--recording-id", "TEST-R02", ok=False)["error"])
        self.assertEqual((self.root / "audio/TEST-R01.wav").read_bytes(), existing)
        self.make_wav(self.wav, seconds=.3)
        (self.root / "audio/TEST-R03.wav").write_bytes(b"preserve")
        self.assertIn("exists", self.import_audio("--recording-id", "TEST-R03", ok=False)["error"])
        self.assertEqual((self.root / "audio/TEST-R03.wav").read_bytes(), b"preserve")

    def test_path_traversal_and_symlink_destination_rejected(self):
        self.grant()
        self.assertIn("identifier", self.import_audio("--recording-id", "../escape", ok=False)["error"])
        outside = self.base / "outside.wav"
        outside.write_bytes(b"safe")
        (self.root / "audio/TEST-R01.wav").symlink_to(outside)
        self.assertIn("path", self.import_audio(ok=False)["error"])
        self.assertEqual(outside.read_bytes(), b"safe")

    def test_ios_nested_sidecar_and_simulator_not_human(self):
        self.grant()
        meta = {"schema_version": 1, "recording_id": "TEST-R01", "recorded_at": "2026-10-16T10:00:00+08:00", "device_type": "iphone", "recording_source": "iphone_microphone", "is_simulated": True, "local_recording_consent": True, "inspection": {"sample_rate": 16000, "channels": 1, "bits_per_sample": 16, "frame_count": 3200, "duration_seconds": .2, "size_bytes": self.wav.stat().st_size, "sha256": hashlib.sha256(self.wav.read_bytes()).hexdigest()}}
        sidecar = self.base / "synthetic.json"
        sidecar.write_text(json.dumps(meta))
        self.import_audio("--metadata", sidecar)
        self.assertEqual(self.rows("WAV_MANIFEST.csv")[0]["recording_source"], "simulator")
        self.assertIn("source", self.call("verify-human", "--recording-id", "TEST-R01", "--reviewer", "TEST-JZD", ok=False)["error"])
        self.assertEqual(self.call("report")["actual_people"], 0)

    def test_sidecar_hash_and_identity_conflict_rejected(self):
        self.grant()
        sidecar = self.base / "synthetic.json"
        for meta, expected in (({"inspection": {"sha256": "0" * 64}}, "sha256"), ({"recording_id": "OTHER"}, "conflict"), ({"local_recording_consent": False}, "consent")):
            with self.subTest(meta=meta):
                sidecar.write_text(json.dumps(meta))
                self.assertIn(expected, self.import_audio("--metadata", sidecar, ok=False)["error"])

    def test_cross_table_hash_and_pointer_tampering_detected(self):
        self.grant()
        self.import_audio()
        row = self.rows("WAV_MANIFEST.csv")[0]
        for key, value, expected in (("sha256", "0" * 64, "sha256"), ("private_storage_pointer", "../outside.wav", "path"), ("speaker_id_pseudonym", "OTHER", "speaker"), ("sample_rate_hz", "8000", "sample_rate_hz")):
            with self.subTest(key=key):
                changed = dict(row, **{key: value})
                self.write_csv("WAV_MANIFEST.csv", MANIFEST, [changed])
                self.assertIn(expected, self.call("validate", ok=False)["error"])

    def test_duplicate_csv_and_non_explicit_consent_values_rejected(self):
        self.grant(recording_allowed="yes")
        self.assertIn("true/false", self.import_audio(ok=False)["error"])
        self.grant()
        rows = self.rows("CONSENT_REGISTER.csv")
        self.write_csv("CONSENT_REGISTER.csv", CONSENT, rows + rows)
        self.assertIn("duplicate", self.call("validate", ok=False)["error"])

    def test_zero_report_and_failed_import_audit(self):
        report = self.call("report")
        self.assertEqual(report["imported_recordings"], 0)
        self.assertEqual(report["actual_people"], 0)
        self.assertEqual(report["acceptance"], "not_accepted")
        self.import_audio(ok=False)
        events = [json.loads(line) for line in (self.root / "audit.jsonl").read_text().splitlines()]
        self.assertEqual(events[-1]["event"], "import_rejected")
        self.assertNotIn(str(self.base), json.dumps(events))

    def test_future_recording_cannot_be_imported(self):
        self.grant()
        self.assertIn("future", self.import_audio("--recorded-at", "2026-10-17T00:00:00+08:00", ok=False)["error"])

    def test_withdrawal_succeeds_even_if_private_audio_was_corrupted(self):
        self.grant()
        self.import_audio()
        (self.root / "audio/TEST-R01.wav").write_bytes(b"corrupt synthetic fixture")
        self.call("withdraw", "--consent-id", "TEST-C01", "--withdrawn-at", "2026-10-16T11:00:00+08:00")
        self.assertEqual(self.rows("CONSENT_REGISTER.csv")[0]["consent_status"], "withdrawn")

    def test_earliest_withdrawal_is_preserved(self):
        self.grant()
        self.assertIn("consent_timestamp", self.call("withdraw", "--consent-id", "TEST-C01", "--withdrawn-at", "2026-09-30T10:00:00+08:00", ok=False)["error"])
        self.call("withdraw", "--consent-id", "TEST-C01", "--withdrawn-at", "2026-10-16T10:00:00+08:00")
        self.assertIn("already", self.call("withdraw", "--consent-id", "TEST-C01", "--withdrawn-at", "2026-10-16T11:00:00+08:00", ok=False)["error"])

    def test_tts_and_synthetic_never_promoted(self):
        self.grant()
        self.import_audio("--recording-source", "tts")
        self.assertIn("source", self.call("verify-human", "--recording-id", "TEST-R01", "--reviewer", "TEST-JZD", ok=False)["error"])
        self.assertEqual(self.call("eligible", "--purpose", "local")["eligible"], [])

    def test_private_root_symlink_and_orphan_audio_rejected(self):
        (self.root / "audio/orphan.wav").write_bytes(b"synthetic orphan")
        self.assertIn("orphan", self.call("validate", ok=False)["error"])
        symlink = self.base / "linked-private"
        symlink.symlink_to(self.root, target_is_directory=True)
        self.root = symlink
        self.assertIn("symlink", self.call("report", ok=False)["error"])

    def test_current_clock_report_uses_shanghai_timezone(self):
        process = subprocess.run([sys.executable, "-B", str(SCRIPT), "report", "--root", str(self.root)], text=True, capture_output=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(json.loads(process.stdout)["as_of"].endswith("+08:00"))

    def test_real_ios_command_uses_sidecar_numeric_values(self):
        self.grant()
        sidecar = self.base / "synthetic.metadata.json"
        sidecar.write_text(json.dumps({"schema_version": 1, "recording_id": "TEST-R01", "utterance_id": "TEST-R01", "recorded_at": "2026-10-16T10:00:00+08:00", "completed_at": "2026-10-16T10:00:01+08:00", "device_type": "iphone", "recording_source": "iphone_microphone", "is_simulated": False, "local_recording_consent": True, "file_name": "TEST-R01.wav", "inspection": {"sample_rate": 16000.0, "channels": 1, "bits_per_sample": 16, "frame_count": 3200, "duration_seconds": .2, "size_bytes": self.wav.stat().st_size, "sha256": hashlib.sha256(self.wav.read_bytes()).hexdigest()}}))
        result = self.call("import", "--wav", self.wav, "--metadata", sidecar, "--consent-id", "TEST-C01", "--speaker-id", "TEST-S01", "--session-id", "TEST-SESSION", "--scene-id", "ordinary")
        self.assertEqual(result["recording"]["quality_status"], "needs_review")
        self.assertEqual(result["recording"]["sample_rate_hz"], "16000")

    def test_untrusted_sidecar_extreme_numbers_rejected_safely(self):
        self.grant()
        sidecar = self.base / "synthetic.json"
        for field in ("sample_rate", "duration_seconds"):
            with self.subTest(field=field):
                sidecar.write_text(json.dumps({"inspection": {field: 10 ** 400}}))
                self.assertIn("mismatch", self.import_audio("--metadata", sidecar, ok=False)["error"])


if __name__ == "__main__":
    unittest.main()
