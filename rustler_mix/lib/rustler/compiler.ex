defmodule Rustler.Compiler do
  @moduledoc false

  alias Rustler.Compiler.{Messages, Rustup}

  @doc false
  def compile_crate(module, opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    config = Application.get_env(otp_app, module, [])

    crate = to_string(config[:crate] || opts[:crate] || otp_app)
    load_data = config[:load_data] || opts[:load_data] || 0
    crate_path = Keyword.get(config, :path, "native/#{crate}")
    crate_full_path = Path.expand(crate_path, File.cwd!())
    build_mode = config[:mode] || opts[:mode] || build_mode(Mix.env())

    external_resources =
      "#{crate_full_path}/**/*"
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        String.starts_with?(path, "#{crate_full_path}/target/")
      end)

    target_dir =
      Keyword.get(
        config,
        :target_dir,
        Path.join([Mix.Project.build_path(), "lib", "#{otp_app}", "native", "#{crate}"])
      )

    priv_dir =
      otp_app
      |> :code.priv_dir()
      |> to_string()

    File.mkdir_p!(priv_dir())

    lib_path = String.to_charlist("#{priv_dir}/native/lib#{crate}")

    cargo_data = check_crate_env(crate_full_path)

    {output_name, output_type} =
      case get_name(cargo_data, "lib") do
        nil ->
          case get_name(cargo_data, "bin") do
            nil -> throw_error({:cargo_no_name, crate_path})
            name -> {name, :bin}
          end

        name ->
          {name, :lib}
      end

    Mix.shell().info("Compiling NIF crate #{crate} (#{crate_path})...")

    compile_command =
      make_base_command(Keyword.get(config, :cargo, :system))
      |> make_no_default_features_flag(Keyword.get(config, :default_features, true))
      |> make_features_flag(Keyword.get(config, :features, []))
      |> make_target_flag(Keyword.get(config, :target, nil))
      |> make_build_mode_flag(build_mode)
      |> make_platform_hacks(crate_full_path, output_type, :os.type())

    [cmd_bin | args] = compile_command

    compile_result =
      System.cmd(cmd_bin, args,
        cd: crate_full_path,
        stderr_to_stdout: true,
        env: [{"CARGO_TARGET_DIR", target_dir} | Keyword.get(config, :env, [])],
        into: IO.stream(:stdio, :line)
      )

    case compile_result do
      {_, 0} -> :ok
      {_, code} -> raise "Rust NIF compile error (rustc exit code #{code})"
    end

    {src_file, dst_file} = make_file_names(output_name, output_type)
    compiled_lib = Path.join([target_dir, Atom.to_string(build_mode), src_file])
    destination_lib = Path.join(priv_dir(), dst_file)

    # If the file exists already, we delete it first. This is to ensure that another
    # process, which might have the library dynamically linked in, does not generate
    # a segfault. By deleting it first, we ensure that the copy operation below does
    # not write into the existing file.
    File.rm(destination_lib)
    File.cp!(compiled_lib, destination_lib)

    {external_resources, lib_path, load_data}
  end

  defp make_base_command(:system), do: ["cargo", "rustc"]
  defp make_base_command({:bin, path}), do: [path, "rustc"]

  defp make_base_command({:rustup, version}) do
    if Rustup.version() == :none do
      throw_error(:rustup_not_installed)
    end

    unless Rustup.version_installed?(version) do
      throw_error({:rust_version_not_installed, version})
    end

    ["rustup", "run", version, "cargo", "rustc"]
  end

  defp make_platform_hacks(args, crate_path, :lib, {:unix, :darwin}) do
    path = Path.join([crate_path, ".cargo", "config"])

    if File.exists?(path) do
      args
    else
      IO.write([
        "\n",
        IO.ANSI.yellow(),
        """
        Compiling on macOS requires special link args in order to compile
        correctly.

        Rustler is currently working around this issue in the compiler task.
        This will be removed in v1.0.0 in favor of a user supplied .cargo/config
        file.

        To remove this warning, please create #{path}
        with the following content:

              [target.x86_64-apple-darwin]
              rustflags = [
                  "-C", "link-arg=-undefined",
                  "-C", "link-arg=dynamic_lookup",
              ]

        See https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/MachOTopics/1-Articles/executing_files.html
        for more details.

        """,
        IO.ANSI.default_color(),
        "\n"
      ])

      args ++ ["--", "-C", "link-arg=-undefined", "-C", "link-arg=dynamic_lookup"]
    end
  end

  defp make_platform_hacks(args, _, _, _), do: args

  defp make_no_default_features_flag(args, true), do: args ++ []
  defp make_no_default_features_flag(args, false), do: args ++ ["--no-default-features"]

  defp make_features_flag(args, []), do: args ++ []
  defp make_features_flag(args, flags), do: args ++ ["--features", Enum.join(flags, ",")]

  defp make_target_flag(args, target) when is_binary(target), do: args ++ ["--target=#{target}"]
  defp make_target_flag(args, _), do: args ++ []

  defp make_build_mode_flag(args, :release), do: args ++ ["--release"]
  defp make_build_mode_flag(args, :debug), do: args ++ []

  defp get_name(cargo_data, section) do
    case cargo_data[section] do
      nil -> nil
      values when is_map(values) -> values["name"]
      values when is_list(values) -> Enum.find_value(values, & &1["name"])
    end
  end

  defp make_file_names(base_name, :lib) do
    case :os.type() do
      {:win32, _} -> {"#{base_name}.dll", "lib#{base_name}.dll"}
      {:unix, :darwin} -> {"lib#{base_name}.dylib", "lib#{base_name}.so"}
      {:unix, _} -> {"lib#{base_name}.so", "lib#{base_name}.so"}
    end
  end

  defp make_file_names(base_name, :bin) do
    case :os.type() do
      {:win32, _} -> {"#{base_name}.exe", "#{base_name}.exe"}
      {:unix, _} -> {base_name, base_name}
    end
  end

  defp throw_error(error_descr) do
    Mix.shell().error(Messages.message(error_descr))
    raise "Compilation error"
  end

  defp check_crate_env(crate) do
    unless File.dir?(crate) do
      throw_error({:nonexistent_crate_directory, crate})
    end

    case File.read("#{crate}/Cargo.toml") do
      {:error, :enoent} ->
        throw_error({:cargo_toml_not_found, crate})

      {:ok, text} ->
        Toml.decode!(text)
    end
  end

  defp build_mode(:prod), do: :release
  defp build_mode(_), do: :debug

  defp priv_dir, do: "priv/native"
end