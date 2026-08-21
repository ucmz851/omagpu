import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ENGINE_PATH = REPO_ROOT / "scripts" / "gpu_engine.py"


def load_engine_module():
    spec = importlib.util.spec_from_file_location("gpu_engine", ENGINE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NvidiaSmiParsingTests(unittest.TestCase):
    def test_parses_each_nvidia_smi_row_as_a_separate_gpu(self):
        engine = load_engine_module()
        output = "\n".join(
            [
                "0, 00000000:C1:00.0, GPU-one, NVIDIA GeForce RTX 4090, 580.95.05, 95.02.3C.00.11, 74, 23028, 0, 35, 0, 19.44, 450.00, 210, 405, 1, 16",
                "1, 00000000:E1:00.0, GPU-two, NVIDIA GeForce RTX 4090, 580.95.05, 95.02.3C.00.12, 833, 24564, 5, 40, 30, 52.13, 450.00, 2550, 10501, 4, 16",
            ]
        )

        gpus = engine.parse_nvidia_smi_output(output)

        self.assertEqual([gpu["index"] for gpu in gpus], [0, 1])
        self.assertEqual([gpu["pciBusId"] for gpu in gpus], ["00000000:C1:00.0", "00000000:E1:00.0"])
        self.assertEqual([gpu["vram"]["totalMb"] for gpu in gpus], [23028.0, 24564.0])
        self.assertEqual([gpu["thermal"]["coreTemp"] for gpu in gpus], [35.0, 40.0])

    def test_preserves_unavailable_nvidia_metrics_as_unknown(self):
        engine = load_engine_module()
        output = "0, 0000:C1:00.0, GPU-one, NVIDIA GPU, 580.95.05, N/A, 0, 1024, 0, N/A, N/A, N/A, N/A, N/A, N/A, N/A, N/A"

        gpu = engine.parse_nvidia_smi_output(output)[0]

        self.assertEqual(gpu["pciBusId"], "00000000:C1:00.0")
        self.assertIsNone(gpu["thermal"]["coreTemp"])
        self.assertIsNone(gpu["thermal"]["fanPwmPercent"])
        self.assertIsNone(gpu["thermal"]["powerWatts"])


class PanelMultiGpuTests(unittest.TestCase):
    def test_panel_exposes_gpu_switching_controls(self):
        panel = (REPO_ROOT / "Panel.qml").read_text()

        self.assertIn("function selectGpu(delta)", panel)
        self.assertIn("id: gpuSelectorRow", panel)
        self.assertIn('text: "GPU " + (index + 1)', panel)
        self.assertIn("text: root.shortBusId(modelData.pciBusId)", panel)
        self.assertIn("onClicked: root.selectedGpuIndex = index", panel)


class LiveMultiGpuTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("nvidia-smi"), "nvidia-smi is required")
    def test_engine_reports_every_nvidia_gpu_with_real_telemetry(self):
        smi = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=index,pci.bus_id,memory.total,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=3,
        )
        expected = []
        for row in smi.stdout.strip().splitlines():
            index, bus_id, memory_total, temperature = [part.strip() for part in row.split(",")]
            expected.append(
                {
                    "index": int(index),
                    "pciBusId": bus_id.upper(),
                    "memoryTotal": float(memory_total),
                    "temperature": float(temperature),
                }
            )

        if len(expected) < 2:
            self.skipTest("two NVIDIA GPUs are required for this regression")

        with tempfile.TemporaryDirectory() as temporary_home:
            environment = os.environ.copy()
            environment["HOME"] = temporary_home
            result = subprocess.run(
                [str(ENGINE_PATH)],
                check=True,
                capture_output=True,
                text=True,
                timeout=5,
                env=environment,
            )
        actual = json.loads(result.stdout)["gpus"]
        actual_nvidia = [gpu for gpu in actual if gpu["vendor"] == "NVIDIA"]

        self.assertEqual(len(actual_nvidia), len(expected))
        for expected_gpu in expected:
            gpu = next(item for item in actual_nvidia if item["index"] == expected_gpu["index"])
            self.assertEqual(gpu["pciBusId"], expected_gpu["pciBusId"])
            self.assertEqual(gpu["vram"]["totalMb"], expected_gpu["memoryTotal"])
            self.assertEqual(gpu["thermal"]["coreTemp"], expected_gpu["temperature"])


if __name__ == "__main__":
    unittest.main()
