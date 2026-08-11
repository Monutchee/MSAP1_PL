# Usage of the script

User-facing Tcl for the product project lives in this directory;
`AI_gen/` below it holds the maintained verification and comparison
scripts (see `AGENTS.md` for when each check runs).

**Vivado GUI rule for every project-mutating script here:** Vivado does
not lock projects, and a live GUI session saves its own in-memory state
over any batch edit. When the product project is open in a GUI, `source`
the script in that session's Tcl console; use `vivado -mode batch
-source <script>` only when no Vivado session is running.

| Name                        | Usage                                                       | Remarks                                                                                                                      |
|-----------------------------|-------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| export_xsa.tcl              | `source SourceData/Script/export_xsa.tcl` (project open)    | Generate the bitstream-inclusive XSA to `runtime-generated/bin_file/`                                                          |
| refresh_hls_ip.tcl          | run after every HLS rebuild (make_HLS.sh does it for you)   | Rebuild the IP catalog against `HLS_DesignFile/ip_repo` and upgrade stale HLS IP customizations so synthesis uses the newest output |
| register_hls_components.tcl | run once after creating a NEW HLS component                 | Generic: discovers every `ip_repo` package by its own VLNV, creates missing `SourceData/IP/<name>_ip` customizations; idempotent |

## export_xsa.tcl

Exports the hardware platform (with bitstream) of the currently open
project to `runtime-generated/bin_file/<project>.xsa`. Requires an open
project, so run it from the GUI Tcl console or after `open_project` in
batch:

```tcl
source SourceData/Script/export_xsa.tcl
```

## refresh_hls_ip.tcl

Makes the project consume the newest packaged HLS output after
`./make_HLS.sh` or `HLS_DesignFile/run_hls.sh` refreshed
`HLS_DesignFile/ip_repo`. Registers the repository on first use, rebuilds
the IP catalog, and upgrades any HLS IP customization whose packaged
revision changed (which also resets its output products, so the next
synthesis regenerates instead of silently reusing stale results).

`./make_HLS.sh` runs this automatically when no Vivado session is
running, and prints the exact command to paste otherwise:

```tcl
# Vivado GUI Tcl console (project open):
source SourceData/Script/refresh_hls_ip.tcl
```

```sh
# no Vivado running:
vivado -mode batch -source SourceData/Script/refresh_hls_ip.tcl
```

Nothing changed → it reports
`All HLS IP customizations already match the packaged revisions.`

## register_hls_components.tcl

One-time project registration for HLS components, generic over every
package below `HLS_DesignFile/ip_repo`: each package's VLNV is read from
its own `component.xml`, a missing customization is created as
`SourceData/IP/<name>_ip` (Vivado reserves the bare IP definition name),
an existing tracked XCI the project lost is re-registered, and stale
customizations are upgraded. Legacy direct-RTL file references under
`HLS_DesignFile` are dropped.

Typical flow after creating a new HLS component:

```sh
./make_HLS.sh                 # builds + packages it into ip_repo
```

```tcl
# then once, in the Vivado Tcl console (or batch when no GUI runs):
source SourceData/Script/register_hls_components.tcl
```

Already-registered components are untouched (`project unchanged`), so
re-running is always safe. What it cannot add is the new component's
maintained VHDL boundary source (its shim, e.g.
`meter_cycle_aggregator_hls_shim.vhd`) — add that to `sources_1`
yourself; the script prints this reminder.
