#!/bin/bash
# patch_xrfdc_mts.sh
# Patches the installed PYNQ xrfdc package to add MTS and SYSREF support.
# Usage:
#   sudo ./patch_xrfdc_mts.sh          # apply patch
#   ./patch_xrfdc_mts.sh --check       # check status only
#   sudo ./patch_xrfdc_mts.sh --revert # revert to backup

XRFDC_DIR="/usr/local/share/pynq-venv/lib/python3.10/site-packages/xrfdc"
FUNCTIONS_C="$XRFDC_DIR/xrfdc_functions.c"
INIT_PY="$XRFDC_DIR/__init__.py"
LIBXRFDC="$XRFDC_DIR/libxrfdc.so"

# --------------------------------------------------------------------------
# Check
# --------------------------------------------------------------------------
do_check() {
    echo "=== xrfdc MTS Patch Status ==="
    echo ""

    # libxrfdc.so symbols
    if nm -D "$LIBXRFDC" 2>/dev/null | grep -q "XRFdc_MultiConverter_Sync"; then
        echo "[OK]     libxrfdc.so contains all required MTS symbols."
    else
        echo "[WARN]   libxrfdc.so is missing MTS symbols."
        echo "         Full PYNQ rebuild may be required (run RFSoC-MTS install.sh)."
    fi

    # xrfdc_functions.c
    if grep -q "XRFdc_MultiConverter_Sync" "$FUNCTIONS_C"; then
        echo "[OK]     xrfdc_functions.c - MTS structs & prototypes"
    else
        echo "[MISSING] xrfdc_functions.c - MTS structs & prototypes"
    fi

    # __init__.py
    if grep -q "mts_adc" "$INIT_PY"; then
        echo "[OK]     __init__.py - mts_adc / mts_dac / sysref_enable methods"
    else
        echo "[MISSING] __init__.py - mts_adc / mts_dac / sysref_enable methods"
    fi
}

# --------------------------------------------------------------------------
# Revert
# --------------------------------------------------------------------------
do_revert() {
    echo "=== Reverting xrfdc MTS Patch ==="
    for f in "$FUNCTIONS_C" "$INIT_PY"; do
        if [ -f "${f}.bak" ]; then
            cp "${f}.bak" "$f"
            echo "[reverted] $f"
        else
            echo "[skip]     no backup found for $f"
        fi
    done
}

# --------------------------------------------------------------------------
# Patch
# --------------------------------------------------------------------------
do_patch() {
    echo "=== Applying xrfdc MTS Patch ==="
    echo ""

    # 1. Verify libxrfdc.so symbols
    if ! nm -D "$LIBXRFDC" 2>/dev/null | grep -q "XRFdc_MultiConverter_Sync"; then
        echo "[ERROR] libxrfdc.so is missing MTS symbols."
        echo "        Run RFSoC-MTS install.sh to rebuild libxrfdc.so first."
        exit 1
    fi
    echo "[OK]   libxrfdc.so symbols verified."

    # 2. Patch xrfdc_functions.c
    if grep -q "XRFdc_MultiConverter_Sync" "$FUNCTIONS_C"; then
        echo "[SKIP] xrfdc_functions.c already patched."
    else
        cp "$FUNCTIONS_C" "${FUNCTIONS_C}.bak"
        echo "[backup] ${FUNCTIONS_C}.bak"
        cat >> "$FUNCTIONS_C" << 'EOF'

typedef struct {
	u32 RefTile;
	u32 IsPLL;
	int Target[4];
	int Scan_Mode;
	int DTC_Code[4];
	int Num_Windows[4];
	int Max_Gap[4];
	int Min_Gap[4];
	int Max_Overlap[4];
} XRFdc_MTS_DTC_Settings;

typedef struct {
	u32 RefTile;
	u32 Tiles;
	int Target_Latency;
	int Offset[4];
	int Latency[4];
	int Marker_Delay;
	int SysRef_Enable;
	XRFdc_MTS_DTC_Settings DTC_Set_PLL;
	XRFdc_MTS_DTC_Settings DTC_Set_T1;
} XRFdc_MultiConverter_Sync_Config;

typedef struct {
	u32 Count[4];
	u32 Loc[4];
} XRFdc_MTS_Marker;

u32 XRFdc_MultiConverter_Sync(XRFdc *InstancePtr, u32 Type, XRFdc_MultiConverter_Sync_Config *ConfigPtr);
void XRFdc_MultiConverter_Init(XRFdc_MultiConverter_Sync_Config *ConfigPtr, int *PLL_CodesPtr, int *T1_CodesPtr);
u32 XRFdc_MTS_Sysref_Config(XRFdc *InstancePtr, XRFdc_MultiConverter_Sync_Config *DACSyncConfigPtr, XRFdc_MultiConverter_Sync_Config *ADCSyncConfigPtr, u32 SysRefEnable);
EOF
        echo "[DONE] xrfdc_functions.c patched."
    fi

    # 3. Patch __init__.py
    if grep -q "mts_adc" "$INIT_PY"; then
        echo "[SKIP] __init__.py already patched."
    else
        cp "$INIT_PY" "${INIT_PY}.bak"
        echo "[backup] ${INIT_PY}.bak"

        # 3a. Add MTS config init inside RFdc.__init__() after dac_tiles line
        ANCHOR="        self.dac_tiles = \[RFdcDacTile(self, i) for i in range(4)\]"
        ADDITION="        self.mts_adc_config = _ffi.new('XRFdc_MultiConverter_Sync_Config*')\n\
        self.mts_dac_config = _ffi.new('XRFdc_MultiConverter_Sync_Config*')\n\
        _safe_wrapper(\"XRFdc_MultiConverter_Init\", self.mts_adc_config, _ffi.NULL, _ffi.NULL)\n\
        _safe_wrapper(\"XRFdc_MultiConverter_Init\", self.mts_dac_config, _ffi.NULL, _ffi.NULL)"
        sed -i "s/$ANCHOR/&\n$ADDITION/" "$INIT_PY"

        # 3b. Add mts_adc / mts_dac / sysref_enable methods after _call_function
        METHOD_ANCHOR="    def _call_function(self, name, \*args):"
        cat >> "$INIT_PY" << 'EOF'


# MTS methods added by patch_xrfdc_mts.sh
def _mts_adc(self):
    """Run Multi-Tile Sync for ADC tiles."""
    return _safe_wrapper("XRFdc_MultiConverter_Sync", self._instance, 0, self.mts_adc_config)

def _mts_dac(self):
    """Run Multi-Tile Sync for DAC tiles."""
    return _safe_wrapper("XRFdc_MultiConverter_Sync", self._instance, 1, self.mts_dac_config)

def _sysref_enable(self, enable):
    """Enable (1) or disable (0) SYSREF capture for MTS."""
    return _safe_wrapper("XRFdc_MTS_Sysref_Config", self._instance,
                         self.mts_dac_config, self.mts_adc_config, enable)

RFdc.mts_adc = _mts_adc
RFdc.mts_dac = _mts_dac
RFdc.sysref_enable = _sysref_enable
EOF
        echo "[DONE] __init__.py patched."
    fi

    echo ""
    echo "Patch complete. Verify with: ./patch_xrfdc_mts.sh --check"
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
case "${1}" in
    --check)  do_check ;;
    --revert) do_revert ;;
    *)
        if [ "$(id -u)" -ne 0 ]; then
            echo "[ERROR] This script must be run as root (sudo)."
            exit 1
        fi
        do_patch
        ;;
esac
