require "exec_from"
require "rwlock"
require "uri"

require "./error"
require "./result"

module PlaceOS::Compiler
  module Git
    Log = ::Log.for(self)

    def self.ls(repository : String, working_directory : String)
      path = repository_path(repository, working_directory)
      result = basic_operation(path) do
        run_git(path, {"ls-files"}, git_args: {"--no-pager"}, raises: true)
      end
      result.output.to_s.split("\n")
    end

    # Commits
    ###############################################################################################

    record Commit, commit : String, date : String, author : String, subject : String

    def self.repository_commits(repository : String, working_directory : String, count : Int32 = 50) : Array(Commit)
      path = repository_path(repository, working_directory)
      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      result = repository_lock(path).write do
        run_git(
          path,
          {"log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s},
          git_args: {"--no-pager"},
          raises: true
        )
      end

      result
        .output.to_s
        .strip.split("<--\n\n-->")
        .reject(&.empty?)
        .map do |line|
          commit = line.strip.split("\n").map(&.strip)
          Commit.new(
            commit: commit[0],
            date: commit[1],
            author: commit[2],
            subject: commit[3],
          )
        end
    end

    def self.commits(file_name : String | Array(String), repository : String, working_directory : String, count : Int32 = 50) : Array(Commit)
      base_arguments = {"log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s, "--"}
      arguments = base_arguments + (file_name.is_a?(String) ? {file_name} : file_name)

      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      path = repository_path(repository, working_directory)
      result = file_operation(path, file_name) do
        run_git(path, arguments, git_args: {"--no-pager"}, raises: true)
      end

      result
        .output.to_s.strip.split("<--\n\n-->")
        .reject(&.empty?)
        .map do |line|
          commit = line.strip.split("\n").map(&.strip)
          Commit.new(
            commit: commit[0],
            date: commit[1],
            author: commit[2],
            subject: commit[3]
          )
        end
    end

    def self.current_file_commit(file_name : String, repository : String, working_directory : String) : String
      commits(file_name, repository, working_directory, 1).first.commit
    end

    def self.current_repository_commit(repository : String, working_directory : String) : String
      repository_commits(repository, working_directory, 1).first.commit
    end

    def self.branches(repository : String, working_directory : String) : Array(String)
      path = repository_path(repository, working_directory)
      result = Git.repo_operation(path) do
        run_git(path, {"fetch", "--all"})
        run_git(path, {"branch", "-r"}, raises: true)
      end

      result
        .output
        .to_s
        .lines
        .compact_map { |l| l.strip.lchop("origin/") unless l =~ /HEAD/ }
        .sort!
        .uniq!
    end

    def self.diff(file_name : String, repository : String, working_directory : String) : String
      path = repository_path(repository, working_directory)
      result = file_operation(path, file_name) do
        run_git(path, {"diff", "--no-color", file_name}, git_args: {"--no-pager"}, raises: true)
      end
      result.output.to_s.strip
    end

    @[Deprecated("Use `Git.checkout_file` instead.")]
    def self.checkout(file : String, repository : String, working_directory : String, commit : String = "HEAD")
      checkout_file(file, repository, working_directory, commit)
    end

    def self.checkout_file(file : String, repository : String, working_directory : String, commit : String = "HEAD")
      path = repository_path(repository, working_directory)
      # https://stackoverflow.com/questions/215718/reset-or-revert-a-specific-file-to-a-specific-revision-using-git
      file_lock(path, file) do
        begin
          _checkout_file(path, file, commit)
          yield file
        ensure
          # reset the file back to head
          _checkout_file(path, file, "HEAD")
        end
      end
    end

    # Checkout a file relative to a repository
    protected def self._checkout_file(repository_directory : String, file : String, commit : String)
      operation_lock(repository_directory).synchronize do
        run_git(repository_directory, {"checkout", commit, "--", file}, raises: true)
      end
    end

    # Checkout a repository to a commit
    protected def self._checkout(repository_directory : String, commit : String)
      operation_lock(repository_directory).synchronize do
        run_git(repository_directory, {"checkout", commit}, raises: true)
      end
    end

    def self.checkout_branch(branch : String, repository : String, working_directory : String)
      path = repository_path(repository, working_directory)
      result = repo_operation(path) do
        run_git(path, {"checkout", branch}, raises: true)
      end
      result.output.to_s.strip
    end

    def self.fetch(repository : String, working_directory : String, remote : String? = nil)
      path = repository_path(repository, working_directory)
      base_arguments = {"fetch", "-a"}
      arguments = remote.nil? ? base_arguments : base_arguments + {remote}

      result = operation_lock(path).synchronize do
        run_git(path, arguments, raises: true)
      end

      result.output.to_s.strip
    end

    def self.pull(repository : String, working_directory : String, branch : String = "master", raises : Bool = false)
      repo_dir = repository_path(repository, working_directory)
      unless File.directory?(File.join(repo_dir, ".git"))
        raise Error::Git.new("repository does not exist at '#{repo_dir}'")
      end

      # Assumes no password required. Re-clone if this has changed.
      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      result = repo_operation(repo_dir) do
        run_git(repo_dir, {"pull", "origin", branch}, raises: raises)
      end

      Result::Command.new(
        exit_code: result.status.exit_code,
        output: result.output.to_s,
      )
    end

    def self.clone(
      repository : String,
      repository_uri : String,
      working_directory : String,
      username : String? = nil,
      password : String? = nil,
      depth : Int32? = nil,
      branch : String = "master",
      raises : Bool = false
    )
      repo_dir = repository_path(repository, working_directory)

      if username && password
        uri_builder = URI.parse(repository_uri)
        uri_builder.user = username
        uri_builder.password = password
        repository_uri = uri_builder.to_s
      end

      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      repository_lock(repo_dir).write do
        # Ensure the repository directory exists (it should)
        Dir.mkdir_p working_directory
        repository_path = File.join(working_directory, repository)

        # Check if there's an existing repo
        if Dir.exists?(File.join(repository_path, ".git"))
          if (current = current_branch(repository_path)) != branch
            begin
              checkout_branch(branch, repository, working_directory)
            rescue e
              if raises
                raise Error::Git.new("failed to update cloned repository branch from #{current} to #{branch}", cause: e)
              else
                Log.warn(exception: e) { "failed to update cloned repository branch from #{current} to #{branch}" }
              end
            end
          end

          Result::Command.new(
            exit_code: 0,
            output: "already exists"
          )
        else
          # Ensure the cloned into directory does not exist
          FileUtils.rm_rf(repository_path) if Dir.exists?(repository_path)

          args = ["clone", repository_uri, repository]
          args.insert(1, "--depth=#{depth}") unless depth.nil?
          args.insert(1, "--branch=#{branch}")

          # Clone the repository
          result = run_git(working_directory, args, raises: raises)
          Result::Command.new(
            exit_code: result.status.exit_code,
            output: result.output.to_s
          )
        end
      end
    end

    # https://stackoverflow.com/questions/6245570/how-to-get-the-current-branch-name-in-git
    def self.current_branch(repository_path : String)
      result = basic_operation(repository_path) do
        run_git(repository_path, {"rev-parse", "--abbrev-ref", "HEAD"}, raises: true)
      end
      result.output.to_s.strip
    end

    def self.current_branch(repository : String, working_directory : String)
      path = repository_path(repository, working_directory)
      current_branch(path)
    end

    # Ensure the expanded repository path is safe
    #
    def self.repository_path(repository : String, working_directory : String)
      working_directory = File.expand_path(working_directory)
      repository_directory = File.expand_path(File.join(working_directory, repository))
      if !repository_directory.starts_with?(working_directory) ||
         repository_directory == "/" ||
         repository.size.zero? ||
         repository.includes?("/") ||
         repository.includes?(".")
        raise Error::Git.new("Invalid folder structure. Working directory: '#{working_directory}', repository: '#{repository}', resulting path: '#{repository_directory}'")
      end

      repository_directory
    end

    protected def self.run_git(
      path,
      args : Enumerable,
      git_args : Enumerable? = nil,
      environment : Hash(String, String) = {} of String => String,
      raises : Bool = false
    )
      environment["GIT_TERMINAL_PROMPT"] = "0"
      args = git_args + args unless git_args.nil? || git_args.empty?
      ExecFrom.exec_from(path, "git", args, environment: environment).tap do |result|
        raise Error::Git.from_result(args, result) if raises && !result.status.success?
      end
    end

    # Repository access synchronization
    ###############################################################################################

    # Use this for simple git operations, such as `git ls`
    def self.basic_operation(repository)
      repository_lock(repository).read do
        operation_lock(repository).synchronize { yield }
      end
    end

    # Use this for simple file operations, such as file commits
    def self.file_operation(repository, file)
      # This is the order of locking that should occur when performing an operation
      # * Read access to repository (not a global change or exclusive access)
      # * File lock ensures exclusive access to this file
      # * Operation lock ensures only a single git command is executing at a time
      #
      # The `checkout` function is an example of performing an operation on a file
      # that requires multiple git operations
      repository_lock(repository).read do
        file_lock(repository, file).synchronize do
          operation_lock(repository).synchronize { yield }
        end
      end
    end

    # Anything that expects a clean repository
    def self.repo_operation(repository)
      repository_lock(repository).write do
        operation_lock(repository).synchronize do
          # Reset incase of a crash during a file operation
          run_git(repository, {"reset", "--hard"}, raises: true)
          yield
        end
      end
    end

    # Locks
    ###############################################################################################

    @@lock_manager = Mutex.new

    # Allow multiple file level operations to occur in parrallel
    # File level operations are readers, repo level are writers
    @@repository_lock = Hash(String, RWLock).new { |h, k| h[k] = RWLock.new }

    # Ensure only a single git operation is occuring at once to avoid corruption
    @@operation_lock = Hash(String, Mutex).new { |h, k| h[k] = Mutex.new }

    # Ensures only a single operation on an individual file occurs at once
    # This enables multi-version compilation to occur without clashing
    @@file_lock = Hash(String, Hash(String, Mutex)).new do |repository_locks, repository|
      repository_locks[repository] = Hash(String, Mutex).new do |file_locks, file|
        file_locks[file] = Mutex.new(:reentrant)
      end
    end

    def self.file_lock(repository, file)
      repository_lock(repository).read do
        file_lock(repository, file).synchronize do
          yield
        end
      end
    end

    def self.file_lock(repository, file) : Mutex
      @@lock_manager.synchronize do
        @@file_lock[repository][file]
      end
    end

    def self.repository_lock(repository) : RWLock
      @@lock_manager.synchronize do
        @@repository_lock[repository]
      end
    end

    def self.operation_lock(repository) : Mutex
      @@lock_manager.synchronize do
        @@operation_lock[repository]
      end
    end
  end
end
