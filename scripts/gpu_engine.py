#!/usr/bin/env python3
"""
OmaGPU Hardware Telemetry & Control Engine
LACT-inspired GPU monitoring, power tuning, fan control, and software inspector.
Supports AMD (amdgpu), NVIDIA (nvidia-smi/NVML), and Intel (i915/xe) graphics.
"""

import sys
import os
import re
import json
import time
import ctypes
import subprocess
from pathlib import Path

HOME = Path.home()
HISTORY_FILE = HOME / ".config" / "omarchy" / "omagpu_history.json"
MAX_HISTORY_POINTS = 30
NVML_FAN_POLICY_MANUAL = 1
NVML_ERR_NO_PERMISSION = 4

NVIDIA_QUERY_FIELDS = [
    "index",
    "pci.bus_id",
    "gpu_uuid",
    "gpu_name",
    "driver_version",
    "vbios_version",
    "memory.used",
    "memory.total",
    "utilization.gpu",
    "temperature.gpu",
    "fan.speed",
    "power.draw",
    "power.limit",
    "clocks.current.graphics",
    "clocks.current.memory",
    "pcie.link.gen.current",
    "pcie.link.width.current",
]


def read_sysfs(path):
    try:
        p = Path(path)
        if p.is_file():
            return p.read_text().strip()
    except Exception:
        pass
    return None


def normalize_pci_bus_id(bus_id):
    if not bus_id:
        return ""
    clean = bus_id.strip()
    parts = clean.split(":")
    if len(parts) == 3:
        domain = parts[0].zfill(8)
        return f"{domain}:{parts[1].zfill(2)}:{parts[2]}".upper()
    if len(parts) == 2:
        return f"00000000:{parts[0].zfill(2)}:{parts[1]}".upper()
    return clean.upper()


def parse_optional_float(value):
    if value is None:
        return None
    cleaned = str(value).strip().replace("[Not Supported]", "").replace("N/A", "")
    if not cleaned:
        return None
    try:
        return round(float(cleaned), 1)
    except ValueError:
        return None


def parse_optional_int(value):
    if value is None:
        return None
    cleaned = str(value).strip().replace("[Not Supported]", "").replace("N/A", "")
    if not cleaned:
        return None
    try:
        return int(float(cleaned))
    except ValueError:
        return None


def parse_nvidia_smi_output(raw_output):
    gpus = []
    lines = [line.strip() for line in raw_output.strip().splitlines() if line.strip()]
    for line in lines:
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < len(NVIDIA_QUERY_FIELDS):
            continue
        values = dict(zip(NVIDIA_QUERY_FIELDS, parts))
        idx = int(values["index"]) if values["index"].isdigit() else len(gpus)
        pci_bus_id = normalize_pci_bus_id(values["pci.bus_id"])
        model_name = values["gpu_name"]
        driver_ver = f"nvidia {values['driver_version']}" if values["driver_version"] else "nvidia"
        vbios_ver = values["vbios_version"] if values["vbios_version"] != "N/A" else "Standard VBIOS"

        used_mb = parse_optional_float(values["memory.used"]) or 0.0
        total_mb = parse_optional_float(values["memory.total"]) or 1024.0
        vram_pct = round((used_mb / total_mb) * 100, 1) if total_mb > 0 else 0.0

        core_temp = parse_optional_float(values["temperature.gpu"])
        hotspot_temp = round(core_temp + 8.0, 1) if core_temp is not None else None
        fan_speed = parse_optional_int(values["fan.speed"])

        cur_gen = values.get("pcie.link.gen.current", "4")
        cur_width = values.get("pcie.link.width.current", "16")
        pcie_info = f"PCIe Gen {cur_gen} x{cur_width}" if cur_gen != "N/A" else "PCIe Gen 4 x16"

        gpus.append({
            "id": f"nvidia{idx}",
            "index": idx,
            "uuid": values.get("gpu_uuid"),
            "pciBusId": pci_bus_id,
            "drmCard": None,
            "vendor": "NVIDIA",
            "model": model_name,
            "driver": driver_ver,
            "vbios": vbios_ver,
            "isPrimary": idx == 0,
            "supportsTuning": True,
            "supportsFanControl": fan_speed is not None,
            "pcie": pcie_info,
            "rebar": True,
            "vram": {
                "usedMb": used_mb,
                "totalMb": total_mb,
                "percent": vram_pct,
            },
            "gtt": {"usedMb": 0.0, "totalMb": 0.0},
            "gpuBusyPercent": parse_optional_int(values["utilization.gpu"]) or 0,
            "memBusyPercent": 0,
            "thermal": {
                "coreTemp": core_temp,
                "hotspotTemp": hotspot_temp,
                "fanRpm": None,
                "fanPwmPercent": fan_speed,
                "powerWatts": parse_optional_float(values["power.draw"]),
                "powerCapWatts": parse_optional_float(values["power.limit"]),
            },
            "tuning": {
                "performanceLevel": "auto",
                "activeProfile": "Auto (Dynamic)",
                "fanControlMode": "Automatic (NVIDIA)",
            },
        })

    return gpus


def query_nvidia_gpus():
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                f"--query-gpu={','.join(NVIDIA_QUERY_FIELDS)}",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=2.0,
        )
        if result.returncode == 0:
            return parse_nvidia_smi_output(result.stdout)
    except (FileNotFoundError, subprocess.SubprocessError):
        pass
    return []


def detect_vulkan_version():
    try:
        res = subprocess.run(["vulkaninfo", "--summary"], capture_output=True, text=True, timeout=1.5)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "Vulkan Instance Version:" in line or "apiVersion" in line:
                    return line.split(":")[-1].strip()
    except Exception:
        pass
    return "Vulkan 1.3 (Mesa Native)"


def detect_opengl_version():
    try:
        res = subprocess.run(["glxinfo", "-B"], capture_output=True, text=True, timeout=1.5)
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "OpenGL version string:" in line or "OpenGL core profile version string:" in line:
                    return line.split(":")[-1].strip()
    except Exception:
        pass
    return "OpenGL 4.6 (Mesa)"


def get_gpu_processes():
    processes = []
    seen_pids = set()
    try:
        render_nodes = list(Path("/dev/dri").glob("renderD*"))
        for node in render_nodes:
            res = subprocess.run(["fuser", str(node)], capture_output=True, text=True, timeout=0.8)
            pids = res.stdout.strip().split()
            for pid in pids:
                pid = pid.strip()
                if pid and pid.isdigit() and pid not in seen_pids:
                    seen_pids.add(pid)
                    comm_path = Path(f"/proc/{pid}/comm")
                    name = comm_path.read_text().strip() if comm_path.exists() else "Unknown"

                    mem_mb = 0
                    statm_path = Path(f"/proc/{pid}/statm")
                    if statm_path.exists():
                        try:
                            pages = int(statm_path.read_text().split()[1])
                            mem_mb = round((pages * 4096) / (1024 * 1024), 1)
                        except Exception:
                            pass

                    processes.append({
                        "pid": int(pid),
                        "name": name,
                        "mem_mb": mem_mb,
                        "type": "3D / Render Client"
                    })
    except Exception:
        pass

    processes.sort(key=lambda x: x["mem_mb"], reverse=True)
    return processes[:8]


def scan_gpus():
    gpus = []
    nvidia_gpus = query_nvidia_gpus()
    nvidia_by_bus = {gpu["pciBusId"]: gpu for gpu in nvidia_gpus}
    matched_nvidia_indices = set()
    drm_cards = sorted(Path("/sys/class/drm").glob("card[0-9]*"))
    actual_cards = [c for c in drm_cards if "-" not in c.name]

    for card in actual_cards:
        dev_path = card / "device"
        if not dev_path.exists():
            continue

        vendor_id = read_sysfs(dev_path / "vendor") or "Unknown"
        device_id = read_sysfs(dev_path / "device") or "Unknown"
        driver_sym = (dev_path / "driver").resolve().name if (dev_path / "driver").exists() else "Unknown"
        boot_vga = read_sysfs(dev_path / "boot_vga") == "1"

        vendor_name = "Generic"
        if "0x1002" in vendor_id.lower():
            vendor_name = "AMD"
        elif "0x10de" in vendor_id.lower():
            vendor_name = "NVIDIA"
        elif "0x8086" in vendor_id.lower():
            vendor_name = "Intel"

        pci_bus_id = normalize_pci_bus_id(dev_path.resolve().name)
        if vendor_name == "NVIDIA" and pci_bus_id in nvidia_by_bus:
            nvidia_gpu = dict(nvidia_by_bus[pci_bus_id])
            nvidia_gpu["drmCard"] = card.name
            nvidia_gpu["isPrimary"] = boot_vga
            gpus.append(nvidia_gpu)
            matched_nvidia_indices.add(nvidia_gpu["index"])
            continue

        model_name = f"{vendor_name} Graphics ({device_id})"
        try:
            # Keep bus:slot.func so lspci doesn't match wrong device across different buses (PR #6)
            pci_slot = ":".join(dev_path.resolve().name.split(":")[-2:]) if ":" in dev_path.resolve().name else "01:00.0"
            lspci_res = subprocess.run(["lspci", "-s", pci_slot], capture_output=True, text=True, timeout=1.0)
            for line in lspci_res.stdout.splitlines():
                if "VGA" in line or "3D" in line or "Display" in line:
                    parts = line.split(":", 2)
                    if len(parts) >= 3:
                        clean_model = parts[2].strip()
                        clean_model = re.sub(r'\[AMD/ATI\]|Advanced Micro Devices, Inc\.|NVIDIA Corporation|Intel Corporation', '', clean_model).strip()
                        model_name = f"{vendor_name} {clean_model}".strip()
                        break
        except Exception:
            pass

        vbios = read_sysfs(dev_path / "vbios_version") or "Standard VBIOS"
        cur_link_speed = read_sysfs(dev_path / "current_link_speed") or "PCIe Gen 3"
        cur_link_width = read_sysfs(dev_path / "current_link_width") or "x8"
        max_link_speed = read_sysfs(dev_path / "max_link_speed") or "PCIe Gen 3"
        max_link_width = read_sysfs(dev_path / "max_link_width") or "x16"
        pcie_info = f"{cur_link_speed} {cur_link_width} (Max: {max_link_speed} {max_link_width})"

        vram_used_bytes = int(read_sysfs(dev_path / "mem_info_vram_used") or 0)
        vram_total_bytes = int(read_sysfs(dev_path / "mem_info_vram_total") or (1024 * 1024 * 1024))
        vram_used_mb = round(vram_used_bytes / (1024 * 1024), 1)
        vram_total_mb = round(vram_total_bytes / (1024 * 1024), 1)
        vram_percent = round((vram_used_mb / vram_total_mb) * 100, 1) if vram_total_mb > 0 else 0

        gtt_used_bytes = int(read_sysfs(dev_path / "mem_info_gtt_used") or 0)
        gtt_total_bytes = int(read_sysfs(dev_path / "mem_info_gtt_total") or 0)
        gtt_used_mb = round(gtt_used_bytes / (1024 * 1024), 1)
        gtt_total_mb = round(gtt_total_bytes / (1024 * 1024), 1)

        gpu_busy = read_sysfs(dev_path / "gpu_busy_percent")
        gpu_busy_pct = int(gpu_busy) if gpu_busy and gpu_busy.isdigit() else None

        mem_busy = read_sysfs(dev_path / "mem_busy_percent")
        mem_busy_pct = int(mem_busy) if mem_busy and mem_busy.isdigit() else None

        hwmon_dirs = list(dev_path.glob("hwmon/hwmon*"))
        temp_c = None
        hotspot_c = None
        fan_rpm = None
        fan_pwm = None
        power_watts = None
        power_cap_watts = None
        fan_mode_val = "Automatic VBIOS"
        supports_fan_control = False

        if hwmon_dirs:
            hdir = hwmon_dirs[0]
            supports_fan_control = (hdir / "pwm1").exists() and (hdir / "pwm1_enable").exists()
            t1 = read_sysfs(hdir / "temp1_input")
            if t1 and t1.isdigit():
                temp_c = round(int(t1) / 1000, 1)

            t2 = read_sysfs(hdir / "temp2_input")
            if t2 and t2.isdigit():
                hotspot_c = round(int(t2) / 1000, 1)

            f1 = read_sysfs(hdir / "fan1_input")
            if f1 and f1.isdigit():
                fan_rpm = int(f1)

            pwm = read_sysfs(hdir / "pwm1")
            if pwm and pwm.isdigit():
                fan_pwm = round((int(pwm) / 255.0) * 100)

            pwm_enable = read_sysfs(hdir / "pwm1_enable")
            if pwm_enable == "1":
                fan_mode_val = "Manual Fixed PWM"
            elif pwm_enable == "2":
                fan_mode_val = "Automatic VBIOS"

            p1 = read_sysfs(hdir / "power1_average") or read_sysfs(hdir / "power1_input")
            if p1 and p1.isdigit():
                power_watts = round(int(p1) / 1000000.0, 1)

            pcap = read_sysfs(hdir / "power1_cap")
            if pcap and pcap.isdigit():
                power_cap_watts = round(int(pcap) / 1000000.0, 1)

        perf_level = read_sysfs(dev_path / "power_dpm_force_performance_level") or "auto"
        power_profile = read_sysfs(dev_path / "pp_power_profile_mode") or "Default"
        supports_tuning = (dev_path / "power_dpm_force_performance_level").exists()

        active_profile_label = "Auto (Dynamic)"
        if "3D_FULL_SCREEN" in power_profile and "*" in power_profile.split("3D_FULL_SCREEN")[0]:
            active_profile_label = "3D Gaming"
        elif "POWER_SAVING" in power_profile and "*" in power_profile.split("POWER_SAVING")[0]:
            active_profile_label = "Power Saving"
        elif "COMPUTE" in power_profile and "*" in power_profile.split("COMPUTE")[0]:
            active_profile_label = "Compute / AI"
        elif perf_level == "high":
            active_profile_label = "High Performance"
        elif perf_level == "low":
            active_profile_label = "Low Power / Quiet"
        elif perf_level == "profile_peak":
            active_profile_label = "Peak Profile"

        vis_vram = int(read_sysfs(dev_path / "mem_info_vis_vram_total") or 0)
        rebar_enabled = vis_vram >= vram_total_bytes and vram_total_bytes > 0

        gpus.append({
            "id": card.name,
            "index": len(gpus),
            "uuid": None,
            "pciBusId": pci_bus_id,
            "drmCard": card.name,
            "vendor": vendor_name,
            "model": model_name,
            "driver": driver_sym,
            "vbios": vbios,
            "isPrimary": boot_vga,
            "supportsTuning": supports_tuning,
            "supportsFanControl": supports_fan_control,
            "pcie": pcie_info,
            "rebar": rebar_enabled,
            "vram": {
                "usedMb": vram_used_mb,
                "totalMb": vram_total_mb,
                "percent": vram_percent
            },
            "gtt": {
                "usedMb": gtt_used_mb,
                "totalMb": gtt_total_mb
            },
            "gpuBusyPercent": gpu_busy_pct if gpu_busy_pct is not None else 0,
            "memBusyPercent": mem_busy_pct if mem_busy_pct is not None else 0,
            "thermal": {
                "coreTemp": temp_c if temp_c is not None else 48.0,
                "hotspotTemp": hotspot_c if hotspot_c is not None else (temp_c + 4.0 if temp_c else 52.0),
                "fanRpm": fan_rpm,
                "fanPwmPercent": fan_pwm if fan_pwm is not None else 35,
                "powerWatts": power_watts if power_watts is not None else 25.0,
                "powerCapWatts": power_cap_watts
            },
            "tuning": {
                "performanceLevel": perf_level,
                "activeProfile": active_profile_label,
                "fanControlMode": fan_mode_val
            }
        })

    # Keep devices visible even when DRM has no card node for one of them
    for nvidia_gpu in nvidia_gpus:
        if nvidia_gpu["index"] not in matched_nvidia_indices:
            gpus.append(nvidia_gpu)

    return gpus


def empty_history():
    return {"temps": [], "vram": [], "gpu_busy": []}


def update_histories(gpus):
    histories = {}
    if HISTORY_FILE.exists():
        try:
            saved = json.loads(HISTORY_FILE.read_text())
            if isinstance(saved.get("gpus"), dict):
                histories = saved["gpus"]
            elif gpus and all(key in saved for key in ("temps", "vram", "gpu_busy")):
                histories[gpus[0]["id"]] = saved
        except Exception:
            histories = {}

    active_ids = {gpu["id"] for gpu in gpus}
    histories = {gpu_id: history for gpu_id, history in histories.items() if gpu_id in active_ids}
    for gpu in gpus:
        history = histories.setdefault(gpu["id"], empty_history())
        temp_val = gpu["thermal"].get("coreTemp")
        if temp_val is not None:
            history["temps"].append(temp_val)
        vram_pct = gpu["vram"].get("percent")
        if vram_pct is not None:
            history["vram"].append(vram_pct)
        gpu_busy_val = gpu.get("gpuBusyPercent")
        if gpu_busy_val is not None:
            history["gpu_busy"].append(gpu_busy_val)

        history["temps"] = history["temps"][-MAX_HISTORY_POINTS:]
        history["vram"] = history["vram"][-MAX_HISTORY_POINTS:]
        history["gpu_busy"] = history["gpu_busy"][-MAX_HISTORY_POINTS:]

    try:
        HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = HISTORY_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps({"version": 2, "gpus": histories}))
        os.replace(tmp, HISTORY_FILE)
    except Exception:
        pass

    return histories


def get_driver(card_id):
    if card_id.startswith("nvidia"):
        return "nvidia"
    driver_link = Path(f"/sys/class/drm/{card_id}/device/driver")
    return driver_link.resolve().name if driver_link.exists() else None


def nvidia_control_target(card_id):
    if card_id.startswith("nvidia"):
        return re.sub(r"\D", "", card_id) or "0"
    dev_path = Path(f"/sys/class/drm/{card_id}/device")
    driver_link = dev_path / "driver"
    if driver_link.exists() and driver_link.resolve().name == "nvidia":
        return dev_path.resolve().name
    return None


def run_self_pkexec(*args):
    if os.geteuid() == 0:
        return {"status": "error", "message": "Permission denied even as root"}
    try:
        res = subprocess.run(
            ["pkexec", sys.executable, os.path.abspath(__file__)] + list(args),
            capture_output=True,
            text=True,
            timeout=90
        )
        if res.returncode == 0 and res.stdout.strip():
            return json.loads(res.stdout.strip())
        if res.returncode in (126, 127):
            return {"status": "error", "message": "Authentication cancelled"}
        return {"status": "error", "message": (res.stderr.strip() or f"pkexec exited {res.returncode}")[:300]}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def nvml_get_handle(lib, target):
    handle = ctypes.c_void_p()
    if target.isdigit():
        rc = lib.nvmlDeviceGetHandleByIndex_v2(int(target), ctypes.byref(handle))
    else:
        rc = lib.nvmlDeviceGetHandleByPciBusId_v2(target.encode(), ctypes.byref(handle))
    return handle if rc == 0 else None


def set_nvidia_fan(target, pwm_val):
    try:
        lib = ctypes.CDLL("libnvidia-ml.so.1")
    except OSError:
        return {"status": "error", "message": "libnvidia-ml.so.1 not found"}
    if lib.nvmlInit_v2() != 0:
        return {"status": "error", "message": "NVML init failed"}
    try:
        handle = nvml_get_handle(lib, target)
        if handle is None:
            return {"status": "error", "message": f"NVML device {target} not found"}
        fan_count = ctypes.c_uint(0)
        if lib.nvmlDeviceGetNumFans(handle, ctypes.byref(fan_count)) != 0 or fan_count.value == 0:
            return {"status": "error", "message": "NVML reports no controllable fans"}

        if pwm_val == "auto":
            for fan in range(fan_count.value):
                rc = lib.nvmlDeviceSetDefaultFanSpeed_v2(handle, fan)
                if rc == NVML_ERR_NO_PERMISSION:
                    return None
                if rc != 0:
                    return {"status": "error", "message": f"NVML error {rc} restoring fan {fan}"}
            return {"status": "success", "mode": "auto", "method": "nvml"}

        try:
            pwm_num = max(0, min(255, int(pwm_val)))
        except ValueError:
            return {"status": "error", "message": f"Invalid PWM value: {pwm_val}"}
        percent = round((pwm_num / 255.0) * 100)
        min_pct = ctypes.c_uint(0)
        max_pct = ctypes.c_uint(100)
        if lib.nvmlDeviceGetMinMaxFanSpeed(handle, ctypes.byref(min_pct), ctypes.byref(max_pct)) == 0:
            percent = max(min_pct.value, min(max_pct.value, percent))
        for fan in range(fan_count.value):
            lib.nvmlDeviceSetFanControlPolicy(handle, fan, NVML_FAN_POLICY_MANUAL)
            rc = lib.nvmlDeviceSetFanSpeed_v2(handle, fan, percent)
            if rc == NVML_ERR_NO_PERMISSION:
                return None
            if rc != 0:
                return {"status": "error", "message": f"NVML error {rc} on fan {fan}"}
        return {"status": "success", "pwm": pwm_num, "method": "nvml"}
    finally:
        lib.nvmlShutdown()


def set_nvidia_performance(card_id, target, level):
    if level not in {"auto", "high", "low", "profile_peak"}:
        return {"status": "error", "message": f"{level} not supported on NVIDIA"}
    if os.geteuid() != 0:
        return run_self_pkexec("--set-power-profile", card_id, level)

    def smi(*args):
        return subprocess.run(["nvidia-smi", "-i", target] + list(args), capture_output=True, text=True, timeout=5.0)

    def query(fields):
        res = smi(f"--query-gpu={fields}", "--format=csv,noheader,nounits")
        if res.returncode != 0 or not res.stdout.strip():
            return None
        return [v.strip() for v in res.stdout.strip().split(",")]

    def watts(value):
        return str(int(float(value)))

    plan = []
    if level == "auto":
        plan = [["-rgc"], ["-rmc"]]
        limits = query("power.default_limit")
        if limits:
            plan.append(["-pl", watts(limits[0])])
    elif level in ("high", "profile_peak"):
        clocks = query("clocks.max.graphics,clocks.max.memory")
        if not clocks or len(clocks) < 2:
            return {"status": "error", "message": "Could not query max clocks"}
        plan = [["-lgc", f"{clocks[0]},{clocks[0]}"], ["-lmc", f"{clocks[1]},{clocks[1]}"]]
        if level == "profile_peak":
            limits = query("power.max_limit")
            if limits:
                plan.append(["-pl", watts(limits[0])])
    elif level == "low":
        res = smi("--query-supported-clocks=graphics", "--format=csv,noheader,nounits")
        if res.returncode != 0 or not res.stdout.strip():
            return {"status": "error", "message": "Could not query supported clocks"}
        min_clock = res.stdout.strip().splitlines()[-1].strip()
        plan = [["-rmc"], ["-lgc", f"{min_clock},{min_clock}"]]
        limits = query("power.min_limit")
        if limits:
            plan.append(["-pl", watts(limits[0])])

    failures = []
    for cmd in plan:
        res = smi(*cmd)
        if res.returncode != 0:
            failures.append(f"{cmd[0]}: {(res.stderr or res.stdout).strip()}")
    if failures:
        return {"status": "error", "message": "; ".join(failures)[:300]}
    return {"status": "success", "level": level, "method": "nvidia-smi"}


def set_performance_level(card_id, level):
    allowed_levels = {"auto", "low", "high", "profile_peak", "manual", "profile_standard", "profile_min_sclk", "profile_min_mclk"}
    if level not in allowed_levels:
        return {"status": "error", "message": f"Invalid DPM level: {level}"}

    nv_target = nvidia_control_target(card_id)
    if nv_target:
        return set_nvidia_performance(card_id, nv_target, level)

    driver = get_driver(card_id)
    dev_path = Path(f"/sys/class/drm/{card_id}/device/power_dpm_force_performance_level")
    if dev_path.exists():
        try:
            dev_path.write_text(level)
            return {"status": "success", "level": level, "method": "direct"}
        except (PermissionError, OSError):
            cmd = f"echo '{level}' > {dev_path}"
            try:
                subprocess.run(["pkexec", "sh", "-c", cmd], check=True, capture_output=True, text=True)
                return {"status": "success", "level": level, "method": "pkexec"}
            except Exception as e:
                return {"status": "error", "message": str(e)}

    return {
        "status": "error",
        "message": f"Not supported: DPM governors are amdgpu-only (driver: {driver or 'unknown'})",
    }


def set_fan_pwm(card_id, pwm_val):
    nv_target = nvidia_control_target(card_id)
    if nv_target:
        result = set_nvidia_fan(nv_target, pwm_val)
        if result is None:
            result = run_self_pkexec("--set-fan", card_id, str(pwm_val))
        return result

    hwmon_dirs = list(Path(f"/sys/class/drm/{card_id}/device/hwmon").glob("hwmon*"))
    if hwmon_dirs:
        hdir = hwmon_dirs[0]
        pwm_file = hdir / "pwm1"
        pwm_enable_file = hdir / "pwm1_enable"

        if pwm_file.exists() and pwm_enable_file.exists() and pwm_val == "auto":
            try:
                pwm_enable_file.write_text("2")
                return {"status": "success", "mode": "auto", "method": "direct"}
            except (PermissionError, OSError):
                cmd = f"echo '2' > {pwm_enable_file}"
                try:
                    subprocess.run(["pkexec", "sh", "-c", cmd], check=True, capture_output=True, text=True)
                    return {"status": "success", "mode": "auto", "method": "pkexec"}
                except Exception as e:
                    return {"status": "error", "message": str(e)}
        elif pwm_file.exists() and pwm_enable_file.exists():
            try:
                pwm_num = max(0, min(255, int(pwm_val)))
            except ValueError:
                return {"status": "error", "message": f"Invalid PWM value: {pwm_val}"}
            try:
                pwm_enable_file.write_text("1")
                pwm_file.write_text(str(pwm_num))
                return {"status": "success", "pwm": pwm_num, "method": "direct"}
            except (PermissionError, OSError):
                cmd = f"echo '1' > {pwm_enable_file} && echo '{pwm_num}' > {pwm_file}"
                try:
                    subprocess.run(["pkexec", "sh", "-c", cmd], check=True, capture_output=True, text=True)
                    return {"status": "success", "pwm": pwm_num, "method": "pkexec"}
                except Exception as e:
                    return {"status": "error", "message": str(e)}

    driver = get_driver(card_id)
    return {
        "status": "error",
        "message": f"Not supported: no fan PWM node exposed (driver: {driver or 'unknown'})",
    }


def main():
    if len(sys.argv) > 1:
        action = sys.argv[1]
        if action == "--set-power-profile" and len(sys.argv) > 3:
            card_id = sys.argv[2]
            level = sys.argv[3]
            print(json.dumps(set_performance_level(card_id, level)))
            return
        elif action == "--set-fan" and len(sys.argv) > 3:
            card_id = sys.argv[2]
            pwm = sys.argv[3]
            print(json.dumps(set_fan_pwm(card_id, pwm)))
            return

    gpus = scan_gpus()
    primary = gpus[0] if gpus else {
        "id": "card0",
        "index": 0,
        "uuid": None,
        "pciBusId": "00000000:00:00.0",
        "drmCard": "card0",
        "vendor": "Generic",
        "model": "Standard Linux Graphics",
        "driver": "drm",
        "vbios": "N/A",
        "isPrimary": True,
        "supportsTuning": False,
        "supportsFanControl": False,
        "pcie": "PCIe Gen 3",
        "rebar": False,
        "vram": {"usedMb": 0, "totalMb": 1024, "percent": 0},
        "gtt": {"usedMb": 0, "totalMb": 0},
        "gpuBusyPercent": 0,
        "memBusyPercent": 0,
        "thermal": {"coreTemp": 45.0, "hotspotTemp": 50.0, "fanRpm": None, "fanPwmPercent": 30, "powerWatts": 20.0, "powerCapWatts": None},
        "tuning": {"performanceLevel": "auto", "activeProfile": "Auto (Dynamic)", "fanControlMode": "Automatic"}
    }

    histories = update_histories(gpus)
    history = histories.get(primary["id"], empty_history())
    processes = get_gpu_processes()
    vulkan_ver = detect_vulkan_version()
    opengl_ver = detect_opengl_version()

    now_str = time.strftime("%H:%M:%S")

    output = {
        "gpus": gpus,
        "primary": primary,
        "history": history,
        "histories": histories,
        "processes": processes,
        "software": {
            "vulkan": vulkan_ver,
            "opengl": opengl_ver,
            "driver": primary["driver"]
        },
        "timestamp": now_str
    }

    print(json.dumps(output, indent=2))


if __name__ == "__main__":
    main()
