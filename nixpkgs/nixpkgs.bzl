load("@bazel_tools//tools/cpp:cc_configure.bzl", "cc_autoconf_impl")

"""Rules for importing Nixpkgs packages."""

def _nixpkgs_git_repository_impl(repository_ctx):
  repository_ctx.file('BUILD')
  # XXX Hack because repository_ctx.path below bails out if resolved path not a regular file.
  repository_ctx.file(repository_ctx.name)
  repository_ctx.download_and_extract(
    url = "%s/archive/%s.tar.gz" % (repository_ctx.attr.remote, repository_ctx.attr.revision),
    stripPrefix = "nixpkgs-" + repository_ctx.attr.revision,
    sha256 = repository_ctx.attr.sha256,
  )

nixpkgs_git_repository = repository_rule(
  implementation = _nixpkgs_git_repository_impl,
  attrs = {
    "revision": attr.string(mandatory = True),
    "remote": attr.string(default = "https://github.com/NixOS/nixpkgs"),
    "sha256": attr.string(),
  },
  local = False,
)

def _nixpkgs_package_impl(repository_ctx):
  repositories = None
  if repository_ctx.attr.repositories:
    repositories = repository_ctx.attr.repositories

  if repository_ctx.attr.repository:
    print("The 'repository' attribute is deprecated, use 'repositories' instead")
    repositories = { repository_ctx.attr.repository: "nixpkgs" } + \
        (repositories if repositories else {})

  if repository_ctx.attr.build_file and repository_ctx.attr.build_file_content:
    fail("Specify one of 'build_file' or 'build_file_content', but not both.")
  elif repository_ctx.attr.build_file:
    repository_ctx.symlink(repository_ctx.attr.build_file, "BUILD")
  elif repository_ctx.attr.build_file_content:
    repository_ctx.file("BUILD", content = repository_ctx.attr.build_file_content)
  else:
    repository_ctx.template("BUILD", Label("@io_tweag_rules_nixpkgs//nixpkgs:BUILD.pkg"))

  strFailureImplicitNixpkgs = (
     "One of 'repositories', 'nix_file' or 'nix_file_content' must be provided. "
     + "The NIX_PATH environment variable is not inherited.")

  expr_args = []
  if repository_ctx.attr.nix_file and repository_ctx.attr.nix_file_content:
    fail("Specify one of 'nix_file' or 'nix_file_content', but not both.")
  elif repository_ctx.attr.nix_file:
    repository_ctx.symlink(repository_ctx.attr.nix_file, "default.nix")
  elif repository_ctx.attr.nix_file_content:
    expr_args = ["-E", repository_ctx.attr.nix_file_content]
  elif not repositories:
    fail(strFailureImplicitNixpkgs)
  else:
    expr_args = ["-E", "import <nixpkgs> {}"]

  # Introduce an artificial dependency with a bogus name on each of
  # the nix_file_deps.
  for dep in repository_ctx.attr.nix_file_deps:
    components = [c for c in [dep.workspace_root, dep.package, dep.name] if c]
    link = '/'.join(components).replace('_', '_U').replace('/', '_S')
    repository_ctx.symlink(dep, link)

  expr_args.extend([
    "-A", repository_ctx.attr.attribute_path
          if repository_ctx.attr.nix_file or repository_ctx.attr.nix_file_content
          else repository_ctx.attr.attribute_path or repository_ctx.attr.name,
    # Creating an out link prevents nix from garbage collecting the store path.
    # nixpkgs uses `nix-support/` for such house-keeping files, so we mirror them
    # and use `bazel-support/`, under the assumption that no nix package has
    # a file named `bazel-support` in its root.
    # A `bazel clean` deletes the symlink and thus nix is free to garbage collect
    # the store path.
    "--out-link", "bazel-support/nix-out-link"
  ])

  # If repositories is not set, leave empty so nix will fail
  # unless a pinned nixpkgs is set in the `nix_file` attribute.
  nix_path = ""
  if repositories:
    nix_path = ":".join(
      [(path_name + "=" + str(repository_ctx.path(target)))
         for (target, path_name) in repositories.items()])
  elif not (repository_ctx.attr.nix_file or repository_ctx.attr.nix_file_content):
    fail(strFailureImplicitNixpkgs)

  nix_build_path = _executable_path(
    repository_ctx,
    "nix-build",
    extra_msg = "See: https://nixos.org/nix/"
  )
  nix_build = [nix_build_path] + expr_args

  # Large enough integer that Bazel can still parse. We don't have
  # access to MAX_INT and 0 is not a valid timeout so this is as good
  # as we can do.
  timeout = 1073741824

  exec_result = _execute_or_fail(
    repository_ctx,
    nix_build,
    failure_message = "Cannot build Nix attribute '{}'.".format(
      repository_ctx.attr.attribute_path
    ),
    quiet = False,
    timeout = timeout,
    environment=dict(NIX_PATH=nix_path),
  )
  output_path = exec_result.stdout.splitlines()[-1]
  # Build a forest of symlinks (like new_local_package() does) to the
  # Nix store.
  _symlink_children(repository_ctx, output_path)


_nixpkgs_package = repository_rule(
  implementation = _nixpkgs_package_impl,
  attrs = {
    "attribute_path": attr.string(),
    "nix_file": attr.label(allow_single_file = [".nix"]),
    "nix_file_deps": attr.label_list(),
    "nix_file_content": attr.string(),
    "repositories": attr.label_keyed_string_dict(),
    "repository": attr.label(),
    "build_file": attr.label(),
    "build_file_content": attr.string(),
  },
  local = True,
)

def nixpkgs_package(*args, **kwargs):
  # Because of https://github.com/bazelbuild/bazel/issues/5356 we can't
  # directly pass a dict from strings to labels to the rule (which we'd like
  # for the `repositories` arguments), but we can pass a dict from labels to
  # strings. So we swap the keys and the values (assuming they all are
  # distinct).
  if "repositories" in kwargs:
    inversed_repositories = { value: key for (key, value) in kwargs["repositories"].items() }
    kwargs.pop("repositories")
    _nixpkgs_package(
      repositories = inversed_repositories,
      *args,
      **kwargs
    )
  else:
    _nixpkgs_package(*args, **kwargs)

def _execute_or_fail(repository_ctx, arguments, failure_message = "", *args, **kwargs):
  """Call repository_ctx.execute() and fail if non-zero return code."""
  result = repository_ctx.execute(arguments, *args, **kwargs)
  if result.return_code:
    outputs = dict(
      failure_message = failure_message,
      arguments = arguments,
      return_code = result.return_code,
      stderr = result.stderr,
    )
    fail("""
{failure_message}
Command: {arguments}
Return code: {return_code}
Error output:
{stderr}
""").format(**outputs)
  return result


def _symlink_children(repository_ctx, target_dir):
  """Create a symlink to all children of `target_dir` in the current
  build directory."""
  find_args = [
    _executable_path(repository_ctx, "find"),
    target_dir,
    "-maxdepth", "1",
    # otherwise the directory is printed as well
    "-mindepth", "1",
    # filenames can contain \n
    "-print0",
  ]
  exec_result = _execute_or_fail(repository_ctx, find_args)
  for target in exec_result.stdout.rstrip("\0").split("\0"):
    basename = target.rpartition("/")[-1]
    repository_ctx.symlink(target, basename)


def _executable_path(repository_ctx, exe_name, extra_msg=""):
  """Try to find the executable, fail with an error."""
  path = repository_ctx.which(exe_name)
  if path == None:
    fail("Could not find the `{}` executable in PATH.{}\n"
          .format(exe_name, " " + extra_msg if extra_msg else ""))
  return path


def _cc_configure_custom(ctx):
  overriden_tools = {
    "gcc": ctx.path(ctx.attr.gcc),
    "ld": ctx.path(ctx.attr.ld),
  }
  return cc_autoconf_impl(ctx, overriden_tools)


cc_configure_custom = repository_rule(
  implementation = _cc_configure_custom,
  attrs = {
    "gcc": attr.label(
      executable=True,
      cfg="host",
      allow_single_file=True,
      doc="`gcc` to use in cc toolchain",
    ),
    "ld": attr.label(
      executable=True,
      cfg="host",
      allow_single_file=True,
      doc="`ld` to use in cc toolchain",
    ),
  },
  local = True,
  environ = [
        "ABI_LIBC_VERSION",
        "ABI_VERSION",
        "BAZEL_COMPILER",
        "BAZEL_HOST_SYSTEM",
        "BAZEL_LINKOPTS",
        "BAZEL_PYTHON",
        "BAZEL_SH",
        "BAZEL_TARGET_CPU",
        "BAZEL_TARGET_LIBC",
        "BAZEL_TARGET_SYSTEM",
        "BAZEL_USE_CPP_ONLY_TOOLCHAIN",
        "BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN",
        "BAZEL_USE_LLVM_NATIVE_COVERAGE",
        "BAZEL_VC",
        "BAZEL_VS",
        "CC",
        "CC_CONFIGURE_DEBUG",
        "CC_TOOLCHAIN_NAME",
        "CPLUS_INCLUDE_PATH",
        "CUDA_COMPUTE_CAPABILITIES",
        "CUDA_PATH",
        "GCOV",
        "HOMEBREW_RUBY_PATH",
        "NO_WHOLE_ARCHIVE_OPTION",
        "SYSTEMROOT",
        "USE_DYNAMIC_CRT",
        "USE_MSVC_WRAPPER",
        "VS90COMNTOOLS",
        "VS100COMNTOOLS",
        "VS110COMNTOOLS",
        "VS120COMNTOOLS",
        "VS140COMNTOOLS",
    ],
)
"""Overwrite cc toolchain by supplying custom `gcc` and `ld` (e.g. from
Nix). This allows to fix mismatch of `gcc` versions between what is used by
packages that come from Nix (e.g. `ghc`) and what Bazel detects
automatically (i.e. system-level `gcc`).
"""
