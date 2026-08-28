#!/usr/bin/env python3
"""Tests for scripts/vm-to-datajson.py — VM JSONL → InfluxDB JSON transformer.

Run: python3 tests/test_vm_to_datajson.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from importlib.util import module_from_spec, spec_from_file_location

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "scripts", "vm-to-datajson.py")

# Import the module under test

spec = spec_from_file_location("vm_to_datajson", SCRIPT)
mod = module_from_spec(spec)
spec.loader.exec_module(mod)
parse_export = mod.parse_export
to_influxdb_json = mod.to_influxdb_json


def _write_jsonl(path, lines):
    with open(path, "w") as f:
        for line in lines:
            f.write(json.dumps(line) + "\n")


class TestParseExport(unittest.TestCase):
    def test_empty_file(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            f.write("")
            f.flush()
            result = parse_export(f.name)
        os.unlink(f.name)
        self.assertEqual(result, {})

    def test_missing_file(self):
        result = parse_export("/nonexistent/file.jsonl")
        self.assertEqual(result, {})

    def test_single_line(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            data = {"timestamps": [1000, 2000], "values": [10, 20]}
            f.write(json.dumps(data) + "\n")
            f.flush()
            result = parse_export(f.name)
        os.unlink(f.name)
        self.assertEqual(result, {1000: 10, 2000: 20})

    def test_multiple_lines(self):
        """VM export can split a single metric across multiple JSONL lines."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            f.write(json.dumps({"timestamps": [1000, 2000], "values": [10, 20]}) + "\n")
            f.write(json.dumps({"timestamps": [3000], "values": [30]}) + "\n")
            f.flush()
            result = parse_export(f.name)
        os.unlink(f.name)
        self.assertEqual(result, {1000: 10, 2000: 20, 3000: 30})

    def test_blank_lines_ignored(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", delete=False) as f:
            f.write("\n")
            f.write(json.dumps({"timestamps": [1000], "values": [42]}) + "\n")
            f.write("\n")
            f.flush()
            result = parse_export(f.name)
        os.unlink(f.name)
        self.assertEqual(result, {1000: 42})


class TestToInfluxdbJson(unittest.TestCase):
    def test_empty_maps(self):
        result = to_influxdb_json({}, {}, {})
        self.assertEqual(result, {"results": [{"series": []}]})

    def test_basic(self):
        ts = 1714000000000  # 2024-04-24T23:06:40Z
        result = to_influxdb_json({ts: 100000000}, {ts: 50000000}, {ts: 12.5})
        series = result["results"][0]["series"][0]
        self.assertEqual(series["name"], "speedtest")
        self.assertEqual(
            series["columns"],
            ["time", "download_bandwidth", "upload_bandwidth", "ping_latency"],
        )
        self.assertEqual(len(series["values"]), 1)
        row = series["values"][0]
        self.assertEqual(row[0], "2024-04-24T23:06:40Z")
        self.assertEqual(row[1], 100000000)
        self.assertEqual(row[2], 50000000)
        self.assertEqual(row[3], 12.5)

    def test_partial_metrics(self):
        """When a timestamp only has some metrics, None fills gaps."""
        result = to_influxdb_json({1000: 100}, {}, {1000: 5.0})
        row = result["results"][0]["series"][0]["values"][0]
        self.assertEqual(row[1], 100)
        self.assertIsNone(row[2])
        self.assertEqual(row[3], 5.0)

    def test_sorted_output(self):
        result = to_influxdb_json(
            {3000: 30, 1000: 10, 2000: 20},
            {3000: 3, 1000: 1, 2000: 2},
            {3000: 0.3, 1000: 0.1, 2000: 0.2},
        )
        values = result["results"][0]["series"][0]["values"]
        timestamps = [v[0] for v in values]
        self.assertEqual(timestamps, sorted(timestamps))

    def test_skips_all_none(self):
        """Rows where all three metrics are None should be skipped."""
        result = to_influxdb_json({1000: None}, {}, {})
        values = result["results"][0]["series"][0].get("values", [])
        self.assertEqual(len(values), 0)


class TestCli(unittest.TestCase):
    def test_invocation(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            _write_jsonl(
                os.path.join(tmpdir, "dl.jsonl"),
                [
                    {"timestamps": [1714000000000], "values": [100000000]},
                ],
            )
            _write_jsonl(
                os.path.join(tmpdir, "ul.jsonl"),
                [
                    {"timestamps": [1714000000000], "values": [50000000]},
                ],
            )
            _write_jsonl(
                os.path.join(tmpdir, "ping.jsonl"),
                [
                    {"timestamps": [1714000000000], "values": [12.5]},
                ],
            )
            result = subprocess.run(
                [sys.executable, SCRIPT, tmpdir],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0)
            data = json.loads(result.stdout)
            self.assertEqual(
                data["results"][0]["series"][0]["columns"],
                ["time", "download_bandwidth", "upload_bandwidth", "ping_latency"],
            )
            self.assertEqual(len(data["results"][0]["series"][0]["values"]), 1)

    def test_empty_dir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            for name in ("dl.jsonl", "ul.jsonl", "ping.jsonl"):
                open(os.path.join(tmpdir, name), "w").close()
            result = subprocess.run(
                [sys.executable, SCRIPT, tmpdir],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0)
            data = json.loads(result.stdout)
            self.assertEqual(data["results"][0]["series"], [])

    def test_output_matches_fixture_structure(self):
        """Verify the output has the same structure as the InfluxDB fixture."""
        fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "data.json")
        with open(fixture_path) as f:
            fixture = json.load(f)

        result = to_influxdb_json(
            {1714000000000: 100000000},
            {1714000000000: 50000000},
            {1714000000000: 12.5},
        )
        # Same top-level keys
        self.assertEqual(set(result.keys()), set(fixture.keys()))
        # Same series structure
        r_series = result["results"][0]["series"][0]
        f_series = fixture["results"][0]["series"][0]
        self.assertEqual(r_series["columns"], f_series["columns"])
        self.assertIn("name", r_series)


if __name__ == "__main__":
    unittest.main()
