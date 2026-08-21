# 🎮 OmaGPU — Linux GPU Controller & Telemetry for Omarchy Quattro

<p align="center">
  <img src="preview.png" alt="OmaGPU Preview" width="460" />
</p>

**OmaGPU** is an advanced hardware telemetry monitor, power governor tuner, fan controller, and software stack inspector built natively for **Omarchy Quattro** (inspired by LACT).

---

## 🌟 Key Features

* **⚡ DPM Power & Clock Tuning:** Switch between dynamic **Auto**, **High Performance** (locked max clocks for gaming & low latency), **Low Power / Silent** (battery saving), and **Peak Profile**.
* **🌡️ Multi-Sensor Telemetry:** Real-time Core Temperature (°C), Hotspot / Junction Temperature (°C), and dynamic thermal warning alerts.
* **💾 VRAM & GTT Memory Breakdown:** Live dedicated VRAM capacity meter and GTT system-shared memory allocations.
* **💨 Acoustics & Fan PWM Tuning:** Switch between automatic VBIOS firmware curves and manual fixed PWM duty cycle presets (`35% Silent`, `60% Balanced`, `80% Aggressive`, `100% Max`).
* **📈 Rolling Telemetry Sparklines:** Built-in 30-second live historical graph tracking temperature and VRAM spikes in real time.
* **🧩 Hardware & Software Stack:** Reports GPU Model, ASIC Family, VBIOS version, PCIe Link Speed/Width, Resizable BAR, Vulkan 1.3/1.4 instance versions, and Mesa/OpenGL versions.
* **🔍 GPU Render Client Inspector:** Inspects active processes utilizing the `/dev/dri` render device (e.g. Hyprland, Chromium, Games) with dedicated RSS memory allocations.

---

## 📸 Screenshots

| Telemetry & Live Graphs | Power & DPM Governors | Hardware & Process Clients |
| :---: | :---: | :---: |
| <img src="screenshots/telemetry.png" width="260" /> | <img src="screenshots/tuning.png" width="260" /> | <img src="screenshots/hardware.png" width="260" /> |

---

## 🛠️ Multi-Vendor Hardware Support

| Vendor | Driver / Interface | Telemetry & Controls Supported |
| :--- | :--- | :--- |
| **AMD** | `amdgpu` (DRM sysfs & hwmon) | GPU %, VRAM / GTT, Core & Hotspot Temp, Fan PWM, DPM Power States, Power Cap. |
| **NVIDIA** | `nvidia` (NVML / nvidia-smi) | GPU %, VRAM, Core & Hotspot Temp, Fan Speed, Power Draw (Watts), Clock Frequencies. |
| **Intel** | `i915` / `xe` (DRM sysfs) | Frequency Scaling (RP0/RPe/RPn), RC6 Power States, Package Temp, Arc Dedicated/Shared VRAM. |

---

## 🚀 Installation & Removal

### Installation
```bash
omarchy plugin add https://github.com/ucmz851/omagpu.git --enable
```

### Removal
```bash
omarchy plugin remove ucmz851.omagpu
```

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
