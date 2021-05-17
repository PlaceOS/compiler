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
        ExecFrom.exec_from(path, "git", {"--no-pager", "ls-files"})
      end

      output = result.output.to_s
      exit_code = result.status.exit_code
      raise CommandFailure.new(exit_code, "git ls-files failed with #{exit_code} in path #{path}: #{output}") unless result.status.success?

      output.split("\n")
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
      result = repo_lock(path).write do
        ExecFrom.exec_from(path, "git", {"--no-pager", "log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s})
      end

      unless result.status.success?
        exit_code = result.status.exit_code
        raise CommandFailure.new(exit_code, "`git log` failed with #{exit_code} in path #{path}: #{result.output}")
      end

      result
        .output.to_s
        .strip.split("<--\n\n-->")
        .reject(&.empty?)
        .map(&.strip.split("\n").map &.strip)
        .map do |commit|
          Commit.new(
            commit: commit[0],
            date: commit[1],
            author: commit[2],
            subject: commit[3],
          )
        end
    end

    def self.commits(file_name : String, repository : String, working_directory : String, count : Int32 = 50) : Array(Commit)
      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      path = repository_path(repository, working_directory)
      result = file_operation(path, file_name) do
        ExecFrom.exec_from(path, "git", {"--no-pager", "log", "--format=format:%h%n%cI%n%an%n%s%n<--%n%n-->", "--no-color", "-n", count.to_s, file_name})
      end

      output = result.output
      exit_code = result.status.exit_code
      raise CommandFailure.new(exit_code, "git log failed with #{exit_code} in path #{repository}: #{output}") unless result.status.success?

      output.to_s.strip.split("<--\n\n-->")
        .reject(&.empty?)
        .map(&.strip.split("\n").map &.strip)
        .map do |commit|
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
      Git.repo_operation(path) do
        ExecFrom.exec_from(path, "git", {"fetch", "--all"}, environment: {"GIT_TERMINAL_PROMPT" => "0"})
        result = ExecFrom.exec_from(path, "git", {"branch", "-r"}, environment: {"GIT_TERMINAL_PROMPT" => "0"})
        exit_code = result.status.exit_code
        output = result.output
        raise CommandFailure.new(exit_code, "`git branch` failed with #{exit_code} in path #{repository}: #{output}") unless result.status.success?

        output
          .to_s
          .lines
          .compact_map { |l| l.strip.lchop("origin/") unless l =~ /HEAD/ }
          .sort!
          .uniq!
      end
    end

    def self.diff(file_name : String, repository : String, working_directory : String) : String
      path = repository_path(repository, working_directory)
      result = file_operation(path, file_name) do
        ExecFrom.exec_from(path, "git", {"--no-pager", "diff", "--no-color", file_name})
      end

      # File most likely doesn't exist
      unless result.status.success?
        exit_code = result.status.exit_code
        raise CommandFailure.new(exit_code, "`git diff` failed with #{exit_code} in path #{path}: #{result.output}")
      end

      result.output.to_s.strip
    end

    def self.checkout(file : String, repository : String, working_directory : String, commit : String = "HEAD")
      path = repository_path(repository, working_directory)
      # https://stackoverflow.com/questions/215718/reset-or-revert-a-specific-file-to-a-specific-revision-using-git
      file_lock(path, file) do
        begin
          _checkout(path, file, commit)
          yield file
        ensure
          # reset the file back to head
          _checkout(path, file, "HEAD")
        end
      end
    end

    # Checkout a file relative to a directory
    protected def self._checkout(repository_directory : String, file : String, commit : String)
      result = operation_lock(repository_directory).synchronize do
        ExecFrom.exec_from(repository_directory, "git", {"checkout", commit, "--", file})
      end

      exit_code = result.status.exit_code
      raise CommandFailure.new(exit_code, "git checkout failed with #{exit_code} in path #{repository_directory}: #{result.output}") unless result.status.success?
    end

    def self.checkout_branch(branch : String, repository : String, working_directory : String)
      path = repository_path(repository, working_directory)
      result = repo_operation(path) do
        ExecFrom.exec_from(path, "git", {"checkout", branch}, environment: {"GIT_TERMINAL_PROMPT" => "0"})
      end

      exit_code = result.status.exit_code
      output = result.output.to_s

      raise CommandFailure.new(exit_code, "git checkout failed with #{exit_code} in path #{path}: #{output}") unless result.status.success?
      output.to_s.strip
    end

    def self.fetch(repository : String, working_directory : String, remote : String? = nil)
      path = repository_path(repository, working_directory)
      base_arguments = {"fetch", "-a"}
      arguments = remote.nil? ? base_arguments : base_arguments + {remote}

      result = operation_lock(path).synchronize do
        ExecFrom.exec_from(path, "git", arguments, environment: {"GIT_TERMINAL_PROMPT" => "0"})
      end

      exit_code = result.status.exit_code
      output = result.output.to_s

      raise CommandFailure.new(exit_code, "git fetch failed with #{exit_code} in path #{path}: #{output}") unless result.status.success?
      output.to_s.strip
    end

    def self.pull(repository : String, working_directory : String, branch : String = "master")
      repo_dir = repository_path(repository, working_directory)
      raise Error.new("repository does not exist. Path: '#{repo_dir}'") unless File.directory?(repo_dir)

      # Assumes no password required. Re-clone if this has changed.
      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      result = repo_operation(repo_dir) do
        ExecFrom.exec_from(repo_dir, "git", {"pull", "origin", branch}, environment: {"GIT_TERMINAL_PROMPT" => "0"})
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
      branch : String = "master"
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
      repo_lock(repo_dir).write do
        # Ensure the repository directory exists (it should)
        Dir.mkdir_p working_directory
        repository_path = File.join(working_directory, repository)

        # Check if there's an existing repo
        if Dir.exists?(File.join(repository_path, ".git"))
          if (current = current_branch(repository_path)) != branch
            begin
              checkout_branch(branch, repository_path, working_directory)
            rescue e
              Log.error(exception: e) { "failed to update cloned repository branch from #{current} to #{branch}" }
            end
          end

          Result::Command.new(
            exit_code: 0,
            output: "already exists"
          )
        else
          # Ensure the cloned into directory does not exist
          ExecFrom.exec_from(working_directory, "rm", {"-rf", repository}) if Dir.exists?(repository_path)

          args = ["clone", repository_uri, repository]
          args.insert(1, "--depth=#{depth}") unless depth.nil?
          args.insert(1, "--branch=#{branch}")

          # Clone the repository
          result = ExecFrom.exec_from(working_directory, "git", args, environment: {"GIT_TERMINAL_PROMPT" => "0"})

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
        ExecFrom.exec_from(repository_path, "git", {"rev-parse", "--abbrev-ref", "HEAD"})
      end

      unless result.status.success?
        exit_code = result.status.exit_code
        raise CommandFailure.new(exit_code, "git rev-parse failed with #{exit_code} in path #{repository_path}: #{result.output}")
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
        raise Error.new("invalid folder structure. Working directory: '#{working_directory}', repository: '#{repository}', resulting path: '#{repository_directory}'")
      end

      repository_directory
    end

    # Repository access synchronization
    ###############################################################################################

    # Will really only be an issue once threads come along
    @@lock_manager = Mutex.new

    # Allow multiple file level operations to occur in parrallel
    # File level operations are readers, repo level are writers
    @@repository_lock = {} of String => RWLock

    # Ensure only a single git operation is occuring at once to avoid corruption
    @@operation_lock = {} of String => Mutex

    # Ensures only a single operation on an individual file occurs at once
    # This enables multi-version compilation to occur without clashing
    @@file_lock = {} of String => Hash(String, Mutex)

    # Use this for simple git operations, such as `git ls`
    def self.basic_operation(repository)
      repo_lock(repository).read do
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
      repo_lock(repository).read do
        file_lock(repository, file).synchronize do
          operation_lock(repository).synchronize { yield }
        end
      end
    end

    # Anything that expects a clean repository
    def self.repo_operation(repository)
      repo_lock(repository).write do
        operation_lock(repository).synchronize do
          # Reset incase of a crash during a file operation
          result = ExecFrom.exec_from(repository, "git", {"reset", "--hard"})

          exit_code = result.status.exit_code
          raise CommandFailure.new(exit_code, "git reset --hard failed with #{exit_code} in path #{repository}: #{result.output}") unless result.status.success?
          yield
        end
      end
    end

    def self.file_lock(repository, file)
      repo_lock(repository).read do
        file_lock(repository, file).synchronize do
          yield
        end
      end
    end

    def self.file_lock(repository, file) : Mutex
      @@lock_manager.synchronize do
        locks = @@file_lock[repository]?
        @@file_lock[repository] = locks = Hash(String, Mutex).new unless locks

        if lock = locks[file]?
          lock
        else
          locks[file] = Mutex.new(:reentrant)
        end
      end
    end

    def self.repo_lock(repository) : RWLock
      @@lock_manager.synchronize do
        if lock = @@repository_lock[repository]?
          lock
        else
          @@repository_lock[repository] = RWLock.new
        end
      end
    end

    def self.operation_lock(repository) : Mutex
      @@lock_manager.synchronize do
        if lock = @@operation_lock[repository]?
          lock
        else
          @@operation_lock[repository] = Mutex.new
        end
      end
    end
  end
end
