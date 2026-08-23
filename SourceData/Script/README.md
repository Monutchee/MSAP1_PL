# Usage of the script

User-facing Tcl for the product project lives in this directory;
`AI_gen/` below it holds the maintained verification and comparison
scripts (see `AGENTS.md` for when each check runs).

The `build_*.tcl` scripts are the staged build the workspace `mnc PL build`
drives, one script per stage so any stage can be rerun by hand.

**Vivado GUI rule for every project-mutating script here:** Vivado does
not lock projects, and a live GUI session saves its own in-memory state
over any batch edit. When the product project is open in a GUI, `source`
the script in that session's Tcl console; use `vivado -mode batch
-source <script>` only when no Vivado session is running.

| Name                        | Usage                                                          | Remarks                                                                                                                             |
|-----------------------------|----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------|
| build_common.tcl            | sourced by the build stages; never run directly                | Shared project location, open/close policy, `-jobs` resolution, `PL_INCREMENTAL` opt-in, run-status checking, and report directory  |
| build_bd.tcl                | `mnc PL build --build-bd`                                      | Validates `TopDesign.bd` and generates its output products, none of which are tracked; required on a fresh checkout                 |
| build_synth.tcl             | `mnc PL build --compile-synth`                                 | Resets and relaunches `synth_1`; reports to `vivado_gen/reports/`                                                                   |
| build_impl.tcl              | `mnc PL build --compile-impl`                                  | Resets `impl_1` and runs it to `route_design` only, so the routed design can be reviewed before it is programmed; `PL_INCREMENTAL=1` reuses the previous routing |
| build_bitstream.tcl         | `mnc PL build --compile-bit`                                   | Writes directly from the completed routed checkpoint, never resetting or relaunching the implementation run                        |
| export_xsa.tcl              | `mnc PL build --gen-xsa`, or `source` it with the project open | Generate the bitstream-inclusive XSA to `runtime-generated/bin_file/`                                                               |
| report_status.tcl           | `mnc PL status`                                                | Read-only: per-run status, progress, and out-of-date flags, plus a single verdict naming what to rerun                              |
| report_summary.tcl          | `mnc PL summary`                                               | Read-only: Vivado's own run statistics (WNS/TNS/WHS/THS, failed nets, power, elapsed) -- the GUI's Design Runs columns              |
| refresh_hls_ip.tcl          | run after every HLS rebuild (`mnc HLS build` does it for you)  | Rebuild the IP catalog against `HLS_DesignFile/ip_repo` and upgrade stale HLS IP customizations so synthesis uses the newest output |
| register_hls_components.tcl | run once after creating a NEW HLS component                    | Generic: discovers every `ip_repo` package by its own VLNV, creates missing `SourceData/IP/<name>_ip` customizations; idempotent    |

## Staged build: build_bd.tcl, build_synth.tcl, build_impl.tcl, build_bitstream.tcl

The build stages the workspace `mnc PL build` drives. One script per stage on
purpose: a failing stage is rerun and debugged on its own instead of
repeating the whole flow.

```sh
./mnc PL build --compile-synth                # from the workspace root
./mnc PL build --compile-impl --compile-bit
./mnc PL build                                # all stages, then XSA + SDTGen
```

Each also runs standalone, taking the `launch_runs -jobs` value as its only
argument (otherwise `VIVADO_JOBS`, otherwise 8):

```sh
vivado -mode batch -source SourceData/Script/build_synth.tcl -tclargs 16
```

```tcl
# Vivado GUI Tcl console (project open):
source SourceData/Script/build_synth.tcl
```

Stage boundaries and what they guarantee:

- `build_bd.tcl` validates the block design and generates its output
  products. It exists because only `TopDesign.bd` and its managed top
  wrapper are tracked: `ip/`, `ipshared/`, `synth/`, `sim/`, and
  `hw_handoff/` are gitignored, so a fresh checkout has no synthesizable
  block-design sources at all. Generation is incremental, so an up-to-date
  design costs one validation pass. The stage never calls `make_wrapper`, so it
  does not re-derive the wrapper from the block-design boundary -- that belongs
  in IP Integrator -- and reports a wrapper older than the `.bd` instead.
  `generate_target` does refresh what it owns, so on a checkout whose products
  were never generated, two tracked files come back modified: the wrapper's
  generated `--Date` header, and the `.bd`'s stored `xci_name`/`xci_path`
  entries, which Vivado normalizes to the cell names. Neither is a design
  change.
- Both `build_bd.tcl` and `build_synth.tcl` first make the project consume the
  newest packaged HLS output. Vitis HLS stamps a fresh `coreRevision` every
  time it packages a component, so after any HLS rebuild the tracked `.xci`
  trails its definition and Vivado locks it. A locked IP cannot be generated,
  its out-of-context run refuses to launch, and synthesis then fails several
  minutes later inside the module reference that instantiates it, with an error
  naming neither HLS nor the revision. The stages therefore rebuild the catalog
  and upgrade a locked `monutchee:*` customization themselves -- the same
  repair `refresh_hls_ip.tcl` performs -- and `build_synth.tcl` refuses to
  launch while any IP is still locked. This is what lets a fresh clone reach a
  bitstream when `make_HLS.sh` skipped its own refresh, which it does whenever
  any Vivado process is alive, including a GUI on an unrelated workspace.
  Upgrading rewrites the `.xci`'s `ip_revision`, so an HLS rebuild always
  leaves that tracked file modified; that is inherent to tracking a file the
  packager re-stamps.
- `build_synth.tcl` resets `synth_1` so the stage always synthesizes the
  current sources. Vivado launches the out-of-context block-design and IP
  runs it depends on; pointing the project at a new packaged HLS revision
  stays the job of `mnc HLS build`/`refresh_hls_ip.tcl`.
- `build_impl.tcl` resets `impl_1` and stops at `route_design`, so timing,
  CDC, DRC, and I/O can be reviewed before a bitstream exists.
- `build_bitstream.tcl` opens the completed routed checkpoint and invokes
  `write_bitstream` directly, so routing is programmed rather than recomputed.
  It does not relaunch or reset `impl_1`. This also avoids a Vivado false
  failure in which Bitgen succeeds but a changed run-hook fingerprint makes
  the parent implementation run report `Out-of-date`.
- The implementation thread hook is a stable, portable project property.
  Build scripts change only its environment-provided thread count, so a later
  read-only status query cannot confuse orchestration metadata with changed
  design inputs. GUI-launched implementation uses the documented default.

Anything other than a completed run raises a Tcl error, so batch Vivado
exits non-zero and `mnc PL build` stops the chain. Reports land in
`vivado_gen/reports/`, per-stage logs in `vivado_gen/logs/`; a report that
cannot be produced warns instead of failing the stage.

`build_common.tcl` holds the shared preamble (project location, open/close
policy, `-jobs` resolution, run-status checking) and is sourced by the stage
scripts, not run directly.

### Incremental implementation: PL_INCREMENTAL

`PL_INCREMENTAL=1` lets place and route reuse the previous routed checkpoint,
which is the one setting that meaningfully shortens an impl rerun after a small
RTL change:

```sh
PL_INCREMENTAL=1 ./mnc PL build --compile-impl --compile-bit
```

It is off by default and deliberately so. An incremental result depends on build
history, so two clones of the same commit can route differently, and reuse can
keep a placement that no longer suits the changed logic -- read the timing
reports rather than assuming them. Rerun without the variable before trusting a
number, and build a release bitstream without it.

`build_impl.tcl` sets Vivado's *automatic* incremental mode
(`AUTO_INCREMENTAL_CHECKPOINT`), never an explicit `INCREMENTAL_CHECKPOINT`
path. The distinction is what keeps a fresh clone working: an explicit path is
saved into the tracked `vivado_gen/MSAP1_PL.xpr`, and Vivado errors out on a
named checkpoint it cannot read instead of falling back to a full run, so a
committed path fails on every clone that has no `.runs` tree yet. In automatic
mode Vivado keeps the reference under `MSAP1_PL.srcs/utils_1/imports/impl_1/`,
which is gitignored and therefore local to each checkout; a missing reference is
simply a normal full run that writes one for next time. The directory sits
outside the run directory, so the stage's `reset_run` does not discard it, and
Vivado drops incremental mode by itself when too little of the design can be
reused.

The stage writes the property on every build, including the default one, so an
opt-in run never leaves the tracked project file claiming incremental is on.

Incremental implementation is a runtime optimisation, so the stage never fails
over it. On a Vivado release that renames the property, drops it, or refuses the
write, `build_impl.tcl` runs a full implementation instead; only an explicit
`PL_INCREMENTAL=1` that could not be honoured prints a warning, so a default
build on such a release behaves exactly as it does today. The reuse is the only
thing at risk, never the bitstream.

## Queries: report_status.tcl, report_summary.tcl

Read-only views of the project, driven by `mnc PL status` and
`mnc PL summary`. Both open the project with `open_project -read_only`, which
cannot save over a live GUI session's in-memory state, so unlike the build
stages they run while the project is open in a GUI.

```sh
./mnc PL status     # what passed, what is out of date, what to rerun
./mnc PL summary    # WNS/TNS/WHS/THS, failed nets, power, elapsed
./mnc PL report     # index the stage reports and logs
./mnc PL report impl_timing_summary          # print one of them
```

`report_status.tcl` prints one row per run -- status, progress, and the
out-of-date flag -- then a single `PL_STATUS_VERDICT` line naming what has to
be rerun. Staleness shows up two ways in Vivado, the `NEEDS_REFRESH`
property and an `Out-of-date` run status, and both count. Out-of-context runs
that never started are counted rather than listed, so the two runs that
matter stay visible.

One thing it deliberately does not report in batch is which IP
customizations are locked: a read-only open makes Vivado report *every* IP as
locked, since none of them can be regenerated in that state. Sourced into a
GUI session that holds the project open for writing, the same script reports
the real count.

`report_summary.tcl` reads the statistics Vivado stored on each run rather
than regenerating a report, so it shows what the last completed run produced
and costs nothing but project load. It prints whichever statistics the
release records, so it does not need updating when that set changes.

`mnc PL report` needs no Vivado at all: the reports are files the
compile stages already wrote to `vivado_gen/reports/`, alongside the
per-stage logs in `vivado_gen/logs/`.

## export_xsa.tcl

Exports the hardware platform (with bitstream) to
`runtime-generated/bin_file/<project>.xsa`, or to the path given as its only
argument -- which is how `mnc PL build --gen-xsa` guarantees the export target
and the SDTGen input are the same file. It opens the product project when no
project is open, so it works from the GUI Tcl console and in batch:

```tcl
source SourceData/Script/export_xsa.tcl
```

```sh
vivado -mode batch -source SourceData/Script/export_xsa.tcl
```

Requires a bitstream, so run `build_bitstream.tcl` (or `mnc PL build
--compile-bit`) first.

## refresh_hls_ip.tcl

Makes the project consume the newest packaged HLS output after
`mnc HLS build` or `HLS_DesignFile/run_hls.sh` refreshed
`HLS_DesignFile/ip_repo`. Registers the repository on first use, rebuilds
the IP catalog, and upgrades any HLS IP customization whose packaged
revision changed (which also resets its output products, so the next
synthesis regenerates instead of silently reusing stale results).

`mnc HLS build` runs this automatically when no Vivado session is
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
./mnc HLS build               # builds + packages it into ip_repo
```

```tcl
# then once, in the Vivado Tcl console (or batch when no GUI runs):
source SourceData/Script/register_hls_components.tcl
```

Already-registered components are untouched (`project unchanged`), so
re-running is always safe. What it cannot add is the new component's
maintained VHDL boundary source (its shim, e.g.
`meter_mtr1_hls_shim.vhd` / `meter_mtr2_hls_shim.vhd`) — add that to `sources_1`
yourself; the script prints this reminder.
