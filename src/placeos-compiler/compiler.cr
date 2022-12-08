require "exec_from"
require "log"

require "./git"
require "./result"

module PlaceOS::Compiler
  Log = ::Log.for(self)

  class_property repository_dir : String = File.expand_path("./repositories")
  class_property binary_dir : String = "#{Dir.current}/bin/drivers"

  class_property crystal_binary_path : String do
    Process.find_executable("crystal") || abort("no `crystal` binary in the environment")
  end

  def self.is_built?(
    source_file : String,
    repository : String,
    commit : String = "HEAD",
    working_directory : String = repository_dir,
    binary_directory : String = binary_dir,
    id : String? = nil
  )
    # Make sure we have an actual version hash of the file
    commit = self.normalize_commit(commit, source_file, repository, working_directory)
    executable_path = File.join(binary_directory, self.executable_name(source_file, commit, id))

    executable_path if File.exists?(executable_path)
  end

  # Repository is required to have a local `build.cr` file to support compilation
  def self.build_driver(
    source_file : String,
    repository : String,
    commit : String = "HEAD",
    working_directory : String = repository_dir,
    binary_directory : String = binary_dir,
    id : String? = nil,
    git_checkout : Bool = true,
    crystal_binary_path : String = crystal_binary_path,
    debug : Bool = false,
    release : Bool = false,
    multithreaded : Bool = false,
    shards_cache : String? = nil,
    build_threads : Int32 = 1,
    branch : String = "master"
  ) : Result::Build
    # Ensure the bin directory exists
    Dir.mkdir_p binary_directory

    # Make sure we have an actual version hash of the file
    commit = normalize_commit(commit, source_file, repository, working_directory)
    driver_executable = executable_name(source_file, commit, id)

    repository_path = Git.repository_path(repository, working_directory)
    executable_path = nil

    result = Git.file_lock(repository_path, source_file) do
      git_checkout = false if commit == "HEAD"

      # TODO: Expose some kind of status signalling compilation
      Log.debug { "compiling #{source_file} @ #{commit}" }

      executable_path = File.join(binary_directory, driver_executable)
      build_script = File.join(repository_path, "src/build.cr")

      # If we are building head and don't want to check anything out
      # then we can assume we definitely want to re-build the driver
      if !git_checkout && File.exists?(executable_path)
        # Deleting a non-existant file will raise an exception
        File.delete(executable_path) rescue nil
      end

      build_args = {
        repository_path:     repository_path,
        executable_path:     executable_path,
        build_script:        build_script,
        source_file:         source_file,
        crystal_binary_path: crystal_binary_path,
        debug:               debug,
        release:             release,
        multithreaded:       multithreaded,
        shards_cache:        shards_cache,
        build_threads:       build_threads,
      }

      # When developing you may not want to have to commit
      if git_checkout
        Git.checkout_file(source_file, repository, working_directory, commit, branch) { _compile(**build_args) }
      else
        _compile(**build_args)
      end
    end

    Result::Build.new(
      output: result.output.to_s,
      exit_code: result.status.exit_code,
      name: driver_executable,
      path: executable_path || "",
      repository: repository_path,
      commit: commit,
    )
  end

  # Ensure that the crystal binary exists, and works as expected
  protected def self.check_crystal!(crystal_binary_path : String) : Nil
    output = IO::Memory.new
    status = Process.run(crystal_binary_path, args: {"-v"}, output: output, error: output)

    # Done to avoid the need to load the whole IO into strings.
    lines = output.rewind.each_line
    first = lines.next
    first = nil if first.is_a?(Iterator::Stop)

    unless status.success? && (first && first.starts_with? "Crystal")
      raise Error.new("running `crystal` at #{crystal_binary_path} failed: #{first}#{"\n#{lines.join("\n")}" unless lines.empty?}")
    end
  end

  protected def self._compile(
    repository_path : String,
    executable_path : String,
    build_script : String,
    source_file : String,
    crystal_binary_path : String,
    debug : Bool,
    release : Bool,
    multithreaded : Bool,
    shards_cache : String?,
    build_threads : Int32
  ) : ExecFrom::Result
    arguments = ["build", "--static", "--no-color", "--error-trace", "--threads", build_threads.to_s, "-o", executable_path, build_script]
    arguments.insert(1, "--debug") if debug
    arguments.insert(1, "--release") if release
    arguments.insert(1, "--Dpreview_mt") if multithreaded

    check_crystal!(crystal_binary_path)
    env = {
      "COMPILE_DRIVER" => source_file,
      "DEBUG"          => debug ? "1" : "0",
    }
    if crystal_path = ENV["CRYSTAL_PATH"]?.presence
      env["CRYSTAL_PATH"] = crystal_path
    end
    env["SHARDS_CACHE_PATH"] = shards_cache if shards_cache

    ExecFrom.exec_from(
      directory: repository_path,
      command: crystal_binary_path,
      arguments: arguments,
      environment: env
    )
  end

  def self.compiled_drivers(source_file : String? = nil, id : String? = nil, binary_directory : String = binary_dir)
    if source_file.nil?
      Dir.children(binary_directory).reject do |file|
        file.includes?(".") || File.directory?(file)
      end
    else
      # Get the executable name without commits to collect all versions
      exec_base = self.driver_slug(source_file)
      Dir.children(binary_directory).select do |file|
        correct_base = file.starts_with?(exec_base) && !file.includes?(".")
        # Select for IDs
        id.nil? ? correct_base : (correct_base && file.ends_with?(id))
      end
    end
  end

  def self.repositories(working_directory : String = repository_dir)
    Dir.children(working_directory).reject { |file| File.file?(file) || file.starts_with?('.') }
  end

  # Runs shards install to ensure driver builds will succeed
  def self.install_shards(repository : String, working_directory : String = repository_dir, shards_cache : String? = nil)
    repo_dir = File.expand_path(File.join(working_directory, repository))
    # NOTE:: supports recursive locking so can perform multiple repository
    # operations in a single lock. i.e. clone + shards install
    Git.repository_lock(repo_dir).write do
      # First check if the dependencies are satisfied
      env = shards_cache.presence ? {"SHARDS_CACHE_PATH" => shards_cache} : {} of String => String?
      result = ExecFrom.exec_from(
        repo_dir,
        "shards", {"--no-color", "check", "--ignore-crystal-version", "--production"},
        environment: env
      )

      output = result.output.to_s
      exit_code = result.status.exit_code

      if exit_code.zero? || output.includes?("Dependencies are satisfied")
        Result::Command.new(
          exit_code: exit_code,
          output: output,
        )
      else
        # Otherwise install shards
        result = ExecFrom.exec_from(
          repo_dir,
          "shards", {"--no-color", "install", "--ignore-crystal-version", "--production"},
          environment: env
        )
        Result::Command.new(
          exit_code: result.status.exit_code,
          output: result.output.to_s,
        )
      end
    end
  end

  def self.clone_and_install(
    repository : String,
    repository_uri : String,
    username : String? = nil,
    password : String? = nil,
    branch : String = "master",
    working_directory : String = repository_dir,
    shards_cache : String? = nil,
    pull_if_exists : Bool = true
  )
    repository_path = Git.repository_path(repository, working_directory)
    Git.repository_lock(repository_path).write do
      clone_result = Git.clone(
        repository: repository,
        repository_uri: repository_uri,
        username: username,
        password: password,
        working_directory: working_directory,
        branch: branch,
        raises: true,
      )

      # Pull if already cloned and pull instead (explicitly checkout latest HEAD)
      if clone_result.output.to_s.includes?("already exists") && pull_if_exists
        Git.pull(repository, working_directory, branch, raises: true)
      end

      install_shards(repository, working_directory, shards_cache).tap do |result|
        raise CommandFailure.new(result.exit_code, "failed to `shards install`: #{result.output}") unless result.success?
      end
    end
  end

  # Removes ".cr" extension and normalises slashes and dots in path
  def self.driver_slug(path : String) : String
    path.rchop(".cr").gsub(/\/|\./, "_")
  end

  # Generate executable name from driver file path and commit
  # Optionally provide an id.
  def self.executable_name(driver_source : String, commit : String, id : String?)
    slug = self.driver_slug(driver_source)
    parts = id.nil? ? {slug, commit} : {slug, commit, id}
    parts.join('_')
  end

  # Ensure commit is an actual SHA reference
  def self.normalize_commit(commit, source_file, repository, working_directory) : String
    changed = Git.diff(source_file, repository, working_directory).empty? rescue false
    # Make sure we have an actual version hash of the file
    if commit == "HEAD" && changed
      # Allow uncommited files to be built
      Git.current_file_commit(source_file, repository, working_directory) rescue commit
    else
      commit
    end
  end
end
