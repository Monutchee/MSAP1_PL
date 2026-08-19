# Vivado Project Template for version control

## Project Initialization

1. Start a new project under `Vivado_gen` folder


## Usage
1. Create a source file under `Source Data/`.

2. Generate the `.tcl` rebuild script after each modification via GUI. 

    a. For normal modification, Use `File -> Project -> Write TCL`

    b. For Block design modification`File -> Export -> Export Block Design`

    c. output Path should be `SourceData/Script/`

3. After clone / update the modification, 
    1. Make sure you navigated to `vivado_gen/` before open the `.xpr` file. Otherwise the vivado dynamic file will be generated on your root of repo directory

    ```
    cd vivado_gen/
    vivado project_name.xpr
    ```

    2. This step seems not necessary to execute on GUI since the `.xpr` file already have the most updated config.
    ```
    source <path_to_your_script>.tcl
    ```


## ADC simulator build switch (K24 targets)

The raw ADC simulator is dev/test infrastructure. The `G_SIMULATOR_ENABLE`
generic on `MeterCore_Wrapper` (default `true`) controls whether it is
elaborated at all:

- `true` — the simulator exists exactly as before (K26 dev builds).
- `false` — the block never enters the netlist (no LUTs/DSPs/BRAM). A
  minimal AXI-lite stub answers its register window with zeros/OKAY, so
  the RPU's probe fails cleanly (`AdcController` isolates simulator-init
  failure and physical metering proceeds); the source mux is pinned to
  the physical front end.

Set it on the block-design module reference without touching sources,
e.g. in a K24 build script:

```tcl
set_property CONFIG.G_SIMULATOR_ENABLE false \
  [get_bd_cells /MeterLogic/MeterCore_Wrapper]
```

`check_meter_core.tcl` elaborates the disabled shape on every run so the
stub branch cannot rot unnoticed.
