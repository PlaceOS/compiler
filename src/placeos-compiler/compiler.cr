require "exec_from"
require "log"

require "./git"
require "./result"

module PlaceOS::Compiler
  Log = ::Log.for(self)

  class_property drivers_dir : String = Dir.current
  class_property repository_dir : String = File.expand_path("./repositories")
  class_property bin_dir : String = "#{Dir.current}/bin/drivers"

  def self.is_built?(
    source_file : String,
    commit : String = "HEAD",
    repository_drivers : String = drivers_dir,
    binary_directory : String = bin_dir,
    id : String? = nil
  )
    # Make sure we have an actual version hash of the file
    commit = self.normalize_commit(commit, source_file, repository_drivers)
    executable_path = File.join(binary_directory, self.executable_name(source_file, commit, id))

    executable_path if File.exists?(executable_path)
  end

  # Repository is required to have a local `build.cr` file to support compilation
  def self.build_driver(
    source_file : String,
    commit : String = "HEAD",
    repository_drivers : String = drivers_dir,
    binary_directory : String = bin_dir,
    id : String? = nil,
    git_checkout : Bool = true,
    debug : Bool = false
  ) : Result::Build
    # Ensure the bin directory exists
    Dir.mkdir_p binary_directory

    # Make sure we have an actual version hash of the file
    commit = normalize_commit(commit, source_file, repository_drivers)
    driver_executable = executable_name(source_file, commit, id)
    executable_path = nil

    result = Git.file_lock(repository_drivers, source_file) do
      git_checkout = false if commit == "HEAD"

      # TODO: Expose some kind of status signalling compilation
      Log.debug { "compiling #{source_file} @ #{commit}" }

      executable_path = File.join(binary_directory, driver_executable)
      build_script = File.join(repository_drivers, "src/build.cr")

      # If we are building head and don't want to check anything out
      # then we can assume we definitely want to re-build the driver
      if !git_checkout && File.exists?(executable_path)
        # Deleting a non-existant file will raise an exception
        File.delete(executable_path) rescue nil
      end

      # When developing you may not want to have to commit
      if git_checkout
        Git.checkout(source_file, commit, repository_drivers) do
          _compile(repository_drivers, executable_path, build_script, source_file, debug)
        end
      else
        _compile(repository_drivers, executable_path, build_script, source_file, debug)
      end
    end

    Result::Build.new(
      output: result.output.to_s,
      exit_code: result.status.exit_code,
      name: driver_executable,
      path: executable_path || "",
      repository: repository_drivers,
      commit: commit,
    )
  end

  def self._compile(
    repository_drivers : String,
    executable_path : String,
    build_script : String,
    source_file : String,
    debug : Bool
  ) : ExecFrom::Result
    arguments = ["build", "--static", "--no-color", "--error-trace", "-o", executable_path, build_script]
    arguments.insert(1, "--debug") if debug

    ExecFrom.exec_from(
      directory: repository_drivers,
      command: "crystal",
      arguments: arguments,
      environment: {
        "COMPILE_DRIVER" => source_file,
        "DEBUG"          => debug ? "1" : "0",
        "CRYSTAL_PATH"   => ENV["CRYSTAL_PATH"]?,
      })
  end

  def self.compiled_drivers(source_file : String? = nil, id : String? = nil, binary_directory : String = bin_dir)
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

  def self.repositories(working_dir : String = repository_dir)
    Dir.children(working_dir).reject { |file| File.file?(file) || file.starts_with?('.') }
  end

  # Runs shards install to ensure driver builds will succeed
  def self.install_shards(repository, working_dir = repository_dir)
    repo_dir = File.expand_path(File.join(working_dir, repository))
    # NOTE:: supports recursive locking so can perform multiple repository
    # operations in a single lock. i.e. clone + shards install
    Git.repo_lock(repo_dir).write do
      # First check if the dependencies are satisfied
      result = ExecFrom.exec_from(repo_dir, "shards", {"--no-color", "check", "--ignore-crystal-version", "--production"})
      output = result.output.to_s
      exit_code = result.status.exit_code

      if exit_code.zero? || output.includes?("Dependencies are satisfied")
        Result::Command.new(
          exit_code: exit_code,
          output: output,
        )
      else
        # Otherwise install shards
        result = ExecFrom.exec_from(repo_dir, "shards", {"--no-color", "install", "--ignore-crystal-version", "--production"})
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
    working_dir : String = repository_dir,
    pull_if_exists : Bool = true
  )
    Git.repo_lock(repository).write do
      clone_result = Git.clone(
        repository: repository,
        repository_uri: repository_uri,
        username: username,
        password: password,
        working_dir: working_dir,
        branch: branch,
      )

      raise "failed to clone\n#{clone_result.output}" unless clone_result.success?

      # Pull if already cloned and pull intended
      if clone_result.output.to_s.includes?("already exists") && pull_if_exists
        pull_result = Git.pull(
          repository: repository,
          working_dir: working_dir,
          branch: branch,
        )
        raise "failed to pull\n#{pull_result.output}" unless pull_result.success?
      end

      install_result = install_shards(repository, working_dir)
      raise "failed to install shards\n#{install_result.output}" unless install_result.success?
    end
  end

  # Removes ".cr" extension and normalises slashes and dots in path
  def self.driver_slug(path : String) : String
    path.rchop(".cr").gsub(/\/|\./, "_")
  end

  # Generate executable name from driver file path and commit
  # Optionally provide an id.
  def self.executable_name(driver_source : String, commit : String, id : String?)
    if id.nil?
      "#{self.driver_slug(driver_source)}_#{commit}"
    else
      "#{self.driver_slug(driver_source)}_#{commit}_#{id}"
    end
  end

  def self.current_commit(source_file, repository)
    Git.commits(source_file, repository, 1).first.commit
  end

  # Ensure commit is an actual version hash of a file
  def self.normalize_commit(commit, source_file, repository) : String
    # Make sure we have an actual version hash of the file
    if commit == "HEAD" && Git.diff(source_file, repository).empty?
      # Allow uncommited files to be built
      self.current_commit(source_file, repository) rescue commit
    else
      commit
    end
  end
end
