# Copyright Google Inc. All Rights Reserved.
#
# Use of this source code is governed by an MIT-style license that can be
# found in the LICENSE file at https://angular.io/license
"""Implementation of the ng_package rule.
"""

load("@build_bazel_rules_nodejs//:internal/collect_es6_sources.bzl", "collect_es6_sources")
load("@build_bazel_rules_nodejs//:internal/rollup/rollup_bundle.bzl",
     "write_rollup_config",
     "rollup_module_mappings_aspect",
     "run_uglify",
     "ROLLUP_ATTRS")
load("@build_bazel_rules_nodejs//:internal/npm_package/npm_package.bzl",
     "NPM_PACKAGE_ATTRS",
     "NPM_PACKAGE_OUTPUTS",
     "create_package")
load("@build_bazel_rules_nodejs//:internal/node.bzl", "sources_aspect")
load("//packages/bazel/src:esm5.bzl", "esm5_outputs_aspect", "ESM5Info")

# TODO(alexeagle): this list is incomplete, add more as material ramps up
WELL_KNOWN_GLOBALS = {
    "@angular/core": "ng.core",
    "@angular/core/testing": "ng.core.testing",
    "@angular/common": "ng.common",
    "@angular/compiler": "ng.compiler",
    "@angular/compiler/testing": "ng.compiler.testing",
    "@angular/platform-browser": "ng.platformBrowser",
    "@angular/platform-browser/testing": "ng.platformBrowser.testing",
    "@angular/platform-browser-dynamic": "ng.platformBrowserDynamic",
}
WELL_KNOWN_GLOBALS.update({"rxjs/%s" % s: "Rx" for s in [
    "BehaviorSubject",
    "ConnectableObservable",
    "Observable",
    "Observer",
    "ReplaySubject",
    "Scheduler",
    "Subject",
    "Subscriber",
    "Subscription",
    "util/EmptyError",
]})
WELL_KNOWN_GLOBALS.update({"rxjs/observable/%s" % s: "Rx.Observable" for s in [
    "combineLatest",
    "concat",
    "defer",
    "empty",
    "forkJoin",
    "from",
    "fromEvent",
    "fromEventPattern",
    "fromPromise",
    "merge",
    "never",
    "of",
    "throw",
]})
WELL_KNOWN_GLOBALS.update({"rxjs/operator/%s" % s: "Rx.Observable.prototype" for s in [
    "catch",
    "concatAll",
    "concatMap",
    "do",
    "every",
    "first",
    "filter",
    "last",
    "map",
    "mergeAll",
    "mergeMap",
    "publish",
    "reduce",
    "share",
    "startWith",
    "switchMap",
    "take",
    "toPromise",
]})
WELL_KNOWN_GLOBALS.update({"rxjs/operators/%s" % s: "Rx.operators" for s in [
    "audit",
    "auditTime",
    "bufferCount",
    "buffer",
    "bufferTime",
    "bufferToggle",
    "bufferWhen",
    "catchError",
    "combineAll",
    "combineLatest",
    "concatAll",
    "concat",
    "concatMap",
    "concatMapTo",
    "count",
    "debounce",
    "debounceTime",
    "defaultIfEmpty",
    "delay",
    "delayWhen",
    "dematerialize",
    "distinct",
    "distinctUntilChanged",
    "distinctUntilKeyChanged",
    "elementAt",
    "every",
    "exhaust",
    "exhaustMap",
    "expand",
    "filter",
    "finalize",
    "findIndex",
    "find",
    "first",
    "groupBy",
    "ignoreElements",
    "isEmpty",
    "last",
    "map",
    "mapTo",
    "materialize",
    "max",
    "mergeAll",
    "merge",
    "mergeMap",
    "mergeMapTo",
    "mergeScan",
    "min",
    "multicast",
    "observeOn",
    "onErrorResumeNext",
    "pairwise",
    "partition",
    "pluck",
    "publishBehavior",
    "publish",
    "publishLast",
    "publishReplay",
    "race",
    "reduce",
    "refCount",
    "repeat",
    "repeatWhen",
    "retry",
    "retryWhen",
    "sample",
    "sampleTime",
    "scan",
    "sequenceEqual",
    "share",
    "shareReplay",
    "single",
    "skip",
    "skipLast",
    "skipUntil",
    "skipWhile",
    "startWith",
    "subscribeOn",
    "switchAll",
    "switchMap",
    "switchMapTo",
    "take",
    "takeLast",
    "takeUntil",
    "takeWhile",
    "tap",
    "throttle",
    "throttleTime",
    "timeInterval",
    "timeout",
    "timeoutWith",
    "timestamp",
    "toArray",
    "windowCount",
    "window",
    "windowTime",
    "windowToggle",
    "windowWhen",
    "withLatestFrom",
    "zipAll",
    "zip",
]})


def _rollup(ctx, rollup_config, entry_point, inputs, js_output, format = "es"):
  map_output = ctx.actions.declare_file(js_output.basename + ".map", sibling = js_output)

  args = ctx.actions.args()
  args.add(["--config", rollup_config.path])

  args.add(["--input", entry_point])
  args.add(["--output.file", js_output.path])
  args.add(["--output.format", format])
  args.add(["--name", ctx.label.name])

  # Note: if the input has external source maps then we need to also install and use
  #   `rollup-plugin-sourcemaps`, which will require us to use rollup.config.js file instead
  #   of command line args
  args.add("--sourcemap")

  globals = dict(WELL_KNOWN_GLOBALS, **ctx.attr.globals)
  externals = globals.keys()
  args.add("--external")
  args.add(externals, join_with=",")

  other_inputs = [ctx.executable._rollup, rollup_config]
  if ctx.file.license_banner:
    other_inputs.append(ctx.file.license_banner)
  if ctx.file.stamp_data:
    other_inputs.append(ctx.file.stamp_data)
  ctx.actions.run(
      progress_message = "Angular Packaging: rolling up %s" % ctx.label.name,
      mnemonic = "AngularPackageRollup",
      inputs = inputs.to_list() + other_inputs,
      outputs = [js_output, map_output],
      executable = ctx.executable._rollup,
      arguments = [args],
  )
  return struct(
      js = js_output,
      map = map_output,
  )

# convert from [{js: js_file1, map: map_file1}, ...] to
# [js_filepath1, map_filepath1, ...]
def _flatten_paths(directory):
  result = []
  for f in directory:
    result.append(f.js.path)
    if f.map:
      result.append(f.map.path)
  return result

# ng_package produces package that is npm-ready.
def _ng_package_impl(ctx):
  npm_package_directory = ctx.actions.declare_directory("%s.ng_pkg" % ctx.label.name)

  esm_2015_files = collect_es6_sources(ctx)

  esm5_sources = depset()
  root_dirs = []

  for dep in ctx.attr.deps:
    if ESM5Info in dep:
      # TODO(alexeagle): we could make the module resolution in the rollup plugin
      # faster if we kept the files grouped with their root dir. This approach just
      # passes in both lists and requires multiple lookups (with expensive exception
      # handling) to locate the files again.
      transitive_output = dep[ESM5Info].transitive_output
      root_dirs.extend(transitive_output.keys())
      esm5_sources = depset(transitive=[esm5_sources] + transitive_output.values())

  # These accumulators match the directory names where the files live in the
  # Angular package format.
  esm2015 = []
  esm5 = []
  bundles = []

  # For Angular Package Format v6, we put all the individual .js files in the
  # esm5/ and esm2015/ folders.
  for f in esm5_sources.to_list():
    if f.path.endswith(".js"):
      esm5.append(struct(js = f, map = None))
  for f in esm_2015_files.to_list():
    if f.path.endswith(".js"):
      esm2015.append(struct(js = f, map = None))

  for entry_point in [""] + ctx.attr.secondary_entry_points:
    es2015_entry_point = "/".join([p for p in [
        ctx.bin_dir.path,
        ctx.label.package,
        ctx.label.name + ".es6",
        ctx.label.package,
        entry_point,
        "index.js",
    ] if p])

    es5_entry_point = "/".join([p for p in [
        ctx.label.package,
        entry_point,
        "index.js",
    ] if p])

    if entry_point:
      # TODO jasonaden says there is no particular reason these filenames differ
      umd_output_filename = "-".join([ctx.label.package.split("/")[-1]] + entry_point.split("/"))
      fesm_output_filename = entry_point.replace("/", "__")
      fesm2015_output = ctx.actions.declare_file("fesm2015/%s.js" % fesm_output_filename)
      fesm5_output = ctx.actions.declare_file("%s.js" % fesm_output_filename)
      umd_output = ctx.actions.declare_file("%s.umd.js" % umd_output_filename)
      min_output = ctx.actions.declare_file("%s.umd.min.js" % umd_output_filename)
    else:
      fesm2015_output = ctx.outputs.fesm2015
      fesm5_output = ctx.outputs.fesm5
      umd_output = ctx.outputs.umd
      min_output = ctx.outputs.umd_min

    config = write_rollup_config(ctx, [], root_dirs)

    # Currently we don't include these rollup "FESM" files in the package.
    # They are only accessible as named outputs from the rule.
    _rollup(ctx, config, es2015_entry_point, esm_2015_files, fesm2015_output)
    _rollup(ctx, config, es5_entry_point, esm5_sources, fesm5_output)

    bundles.append(_rollup(ctx, config, es5_entry_point, esm5_sources, umd_output, format = "umd"))
    uglify_sourcemap = run_uglify(ctx, umd_output, min_output,
        config_name = entry_point.replace("/", "_"))
    bundles.append(struct(js = min_output, map = uglify_sourcemap))

  metadata_files = depset(transitive = [getattr(dep, "angular").flat_module_metadata
                                        for dep in ctx.attr.deps
                                        if hasattr(dep, "angular")])

  args = ctx.actions.args()
  args.use_param_file("%s", use_always = True)

  # The order of arguments matters here, as they are read in order in packager.ts.
  args.add(npm_package_directory.path)
  args.add(ctx.label.package)
  args.add(primary_entry_point_name(ctx.attr.name, ctx.attr.entry_point))
  args.add(ctx.attr.secondary_entry_points, join_with=",")
  args.add([ctx.bin_dir.path, ctx.label.package], join_with="/")
  args.add(ctx.file.readme_md.path if ctx.file.readme_md else "")
  args.add(_flatten_paths(esm2015), join_with=",")
  args.add(_flatten_paths(esm5), join_with=",")
  args.add(_flatten_paths(bundles), join_with=",")
  args.add([s.path for s in ctx.files.srcs], join_with=",")
  args.add(ctx.file.license_banner.path if ctx.file.license_banner else "")

  other_inputs = (metadata_files.to_list() +
      [f.js for f in esm2015 + esm5 + bundles] +
      [f.map for f in esm2015 + esm5 + bundles if f.map])
  if ctx.file.readme_md:
    other_inputs.append(ctx.file.readme_md)
  if ctx.file.license_banner:
    other_inputs.append(ctx.file.license_banner)

  ctx.actions.run(
      progress_message = "Angular Packaging: building npm package for %s" % ctx.label.name,
      mnemonic = "AngularPackage",
      inputs = esm5_sources.to_list() +
          depset(transitive = [d.typescript.transitive_declarations
              for d in ctx.attr.deps
              if hasattr(d, "typescript")]).to_list() +
          ctx.files.srcs +
          other_inputs,
      outputs = [npm_package_directory],
      executable = ctx.executable._ng_packager,
      arguments = [args],
  )

  devfiles = depset()
  if ctx.attr.include_devmode_srcs:
    for d in ctx.attr.deps:
      devfiles = depset(transitive = [devfiles, d.files, d.node_sources])

  package_dir = create_package(ctx, devfiles.to_list(), [npm_package_directory])
  return struct(
    files = depset([package_dir])
  )

NG_PACKAGE_ATTRS = dict(NPM_PACKAGE_ATTRS, **dict(ROLLUP_ATTRS, **{
    "srcs": attr.label_list(allow_files = True),
    "deps": attr.label_list(aspects = [
        rollup_module_mappings_aspect,
        esm5_outputs_aspect,
        sources_aspect,
    ]),
    "include_devmode_srcs": attr.bool(default = False),
    "readme_md": attr.label(allow_single_file = FileType([".md"])),
    "globals": attr.string_dict(default={}),
    "secondary_entry_points": attr.string_list(),
    "_ng_packager": attr.label(
        default=Label("//packages/bazel/src/ng_package:packager"),
        executable=True, cfg="host"),
    "_rollup": attr.label(
        default=Label("@build_bazel_rules_nodejs//internal/rollup"),
        executable=True, cfg="host"),
    "_rollup_config_tmpl": attr.label(
        default=Label("@build_bazel_rules_nodejs//internal/rollup:rollup.config.js"),
        allow_single_file=True),
    "_uglify": attr.label(
        default=Label("@build_bazel_rules_nodejs//internal/rollup:uglify"),
        executable=True, cfg="host"),
}))

# Angular wants these named after the entry_point,
# eg. for //packages/core it looks like "packages/core/index.js", we want
# core.js produced by this rule.
# Currently we just borrow the entry point for this, if it looks like
# some/path/to/my/package/index.js
# we assume the files should be named "package.*.js"
def primary_entry_point_name(name, entry_point):
  return entry_point.split("/")[-2] if entry_point.find("/") >=0 else name

def ng_package_outputs(name, entry_point):
  basename = primary_entry_point_name(name, entry_point)
  outputs = {
      "fesm5": "fesm5/%s.js" % basename,
      "fesm2015": "fesm2015/%s.js" % basename,
      "umd": "%s.umd.js" % basename,
      "umd_min": "%s.umd.min.js" % basename,
  }
  for key in NPM_PACKAGE_OUTPUTS:
    # NPM_PACKAGE_OUTPUTS is a "normal" dict-valued outputs so it looks like
    #  "pack": "%{name}.pack",
    # But this is a function-valued outputs.
    # Bazel won't replace the %{name} token so we have to do it.
    outputs[key] = NPM_PACKAGE_OUTPUTS[key].replace("%{name}", name)
  return outputs

ng_package = rule(
    implementation = _ng_package_impl,
    attrs = NG_PACKAGE_ATTRS,
    outputs = ng_package_outputs,
)
