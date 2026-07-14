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

