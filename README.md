# rfsoc_mts_patch

Lightweight patch for the PYNQ xrfdc package to enable Multi-Tile Sync (MTS) and SYSREF control on RFSoC boards — no full PYNQ rebuild required.

## Usage

```bash
# Check whether the patch is already applied
./patch_xrfdc_mts.sh --check

# Apply the patch
sudo ./patch_xrfdc_mts.sh

# Revert to original (uses .bak files created during patching)
sudo ./patch_xrfdc_mts.sh --revert
```

After patching:

```python
from pynq import Overlay

ol = Overlay("your_design.bit")
rfdc = ol.usp_rf_data_converter_0  # adjust to your IP name

# Optionally configure which tiles to sync (bitmask, bit N = tile N)
rfdc.mts_adc_config.Tiles = 0b0011  # tiles 0 and 1
rfdc.mts_dac_config.Tiles = 0b0011
rfdc.mts_adc_config.RefTile = 0
rfdc.mts_dac_config.RefTile = 0

# Run MTS sequence
rfdc.sysref_enable(0)
# ... configure mixer frequencies, etc. ...
rfdc.sysref_enable(1)
rfdc.mts_adc()
rfdc.mts_dac()
rfdc.sysref_enable(0)
```

**Requirements:** Tested on RFSoC4x2 PYNQ v3.0. The script checks that `libxrfdc.so` already contains the MTS symbols before patching — if not, a full rebuild via [RFSoC-MTS](https://github.com/Xilinx/RFSoC-MTS) is required first.

---

## Background

### Why MTS is needed

The RFSoC RF Data Converter IP contains multiple independent DAC/ADC tiles, each with its own PLL and datapath. When using converters across different tiles simultaneously, they are not inherently synchronized — each tile starts up with an arbitrary phase offset relative to the others.

**Multi-Tile Sync (MTS)** aligns all tiles to a common reference using two signals fed into the RF Data Converter IP from the PL:

- `PL_CLK` → shared clock distributed to all tiles that need synchronization
- `PL_SYSREF` → `user_sysref_dac` / `user_sysref_adc` — a periodic reference pulse used to capture and align each tile's internal timing

### Why this patch is needed

AMD provides MTS C API functions in the embeddedsw library:

| C Function | Role |
|-----------|------|
| `XRFdc_MultiConverter_Init` | Initialize MTS config struct |
| `XRFdc_MultiConverter_Sync` | Run tile synchronization |
| `XRFdc_MTS_Sysref_Config` | Enable / disable SYSREF capture |

However, the default PYNQ xrfdc Python package does not expose these functions. The `xrfdc_functions.c` file (used by CFFI to generate Python bindings at runtime) lacks the MTS struct definitions and function prototypes, and the `RFdc` Python class has no corresponding methods.

The existing [RFSoC-MTS](https://github.com/Xilinx/RFSoC-MTS) repository addresses this by patching the PYNQ source and rebuilding `libxrfdc.so` from scratch. However, on modern PYNQ images, **`libxrfdc.so` already contains all three MTS symbols** — only the Python-side bindings are missing. A full rebuild is unnecessary.

This patch takes the lightweight approach: update only the two files that CFFI and Python read at runtime.

### What this patch modifies

**`xrfdc_functions.c`** — adds MTS C struct definitions and function prototypes so CFFI can resolve them:
- `XRFdc_MTS_DTC_Settings`
- `XRFdc_MultiConverter_Sync_Config`
- `XRFdc_MTS_Marker`
- `XRFdc_MultiConverter_Sync()`, `XRFdc_MultiConverter_Init()`, `XRFdc_MTS_Sysref_Config()`

**`__init__.py`** — adds to the `RFdc` class:
- `mts_adc_config`, `mts_dac_config` — MTS config structs initialized in `__init__()`
- `mts_adc()` — synchronize ADC tiles
- `mts_dac()` — synchronize DAC tiles
- `sysref_enable(enable)` — enable/disable SYSREF capture
