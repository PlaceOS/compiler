require "exec_from"
require "file_utils"
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

    record Commit, commit : String, date : String, author : String, subject : String do
      include JSON::Serializable
    end

    def self.repository_commits(repository : String, working_directory : String, count : Int32 = 50, branch : String? = "master") : Array(Commit)
      _commits(nil, repository, working_directory, count, branch)
    end

    def self.commits(file_name : String | Array(String), repository : String, working_directory : String, count : Int32 = 50, branch : String? = "master") : Array(Commit)
      _commits(file_name, repository, working_directory, count, branch)
    end

    private LOG_FORMAT = "format:%H%n%cI%n%an%n%s%n<--%n%n-->"

    protected def self._commits(file_name : String | Array(String) | Nil, repository : String, working_directory : String, count : Int32 = 50, branch : String? = "master")
      arguments = [
        "log",
        "--format=#{LOG_FORMAT}",
        "--no-color",
        "-n", count.to_s,
      ]

      # If the branch is included, the up-to-date commit lists of the branch is fetched
      # Otherwise, commits from the current checked out commit are returned
      arguments << "origin/#{branch}" unless branch.nil?

      case file_name
      in String
        arguments << "--"
        arguments << file_name
      in Array(String)
        arguments << "--"
        arguments.concat(file_name)
      in Nil
      end

      # https://git-scm.com/docs/pretty-formats
      # %h: abbreviated commit hash
      # %cI: committer date, strict ISO 8601 format
      # %an: author name
      # %s: subject
      path = repository_path(repository, working_directory)
      result = repository_lock(path).read do
        run_git(path, {"fetch", "--all"})
        run_git(path, arguments, git_args: {"--no-pager"}, raises: true)
      end

      result
        .output.tap(&.rewind)
        .each_line("<--\n\n-->")
        .reject(&.empty?)
        .map { |line|
          commit = line.strip.split("\n").map(&.strip)
          Commit.new(
            commit: commit[0],
            date: commit[1],
            author: commit[2],
            subject: commit[3]
          )
        }.to_a
    end

    def self.current_file_commit(file_name : String, repository : String, working_directory : String) : String
      # Branch is `nil` as we want commits from the _current_ repo state
      commits(file_name, repository, working_directory, 1, branch: nil).first.commit
    end

    def self.current_repository_commit(repository : String, working_directory : String) : String
      # Branch is `nil` as we want commits from the _current_ repo state
      repository_commits(repository, working_directory, 1, branch: nil).first.commit
    end

    def self.remote(repository : String, working_directory : String) : String
      path = repository_path(repository, working_directory)
      run_git(path, {"config", "--get", "remote.origin.url"}, raises: true).output.to_s.chomp
    end

    def self.branches(repository : String, working_directory : String) : Array(String)
      path = repository_path(repository, working_directory)
      result = Git.repo_operation(path) do
        run_git(path, {"fetch", "--all"})
        run_git(path, {"branch", "-r"}, raises: true)
      end

      result
        .output.tap(&.rewind)
        .each_line
        .compact_map { |l| l.strip.lchop("origin/") unless l =~ /HEAD/ }
        .to_a
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

    def self.checkout_file(file : String, repository : String, working_directory : String, commit : String = "HEAD", branch : String = "master")
      path = repository_path(repository, working_directory)
      current = current_branch(path)
      file_lock(path, file) do
        begin
          _checkout_file(path, file, commit, branch)
          yield file
        ensure
          _restore(path, current)
        end
      end
    end

    # :nodoc:
    def self._restore(repository_directory : String, source : String, path : String = ".")
      operation_lock(repository_directory).synchronize do
        run_git(repository_directory, {"restore", "--source", source, "--", path}, raises: true)
      end
    end

    # :nodoc:
    # Checkout a file relative to a repository
    def self._checkout_file(repository_directory : String, file : String, commit : String, branch : String)
      operation_lock(repository_directory).synchronize do
        run_git(repository_directory, {"checkout", "--force", branch}, raises: true)
        run_git(repository_directory, {"checkout", commit, "--", file}, raises: true)
      end
    end

    # :nodoc:
    # Checkout a repository to a reference
    def self._checkout(
      repository_directory : String,
      reference : String,
      raises : Bool = true,
      force : Bool = false
    )
      arguments = ["checkout", reference]
      arguments << "--force" if force
      operation_lock(repository_directory).synchronize do
        run_git(repository_directory, arguments, raises: raises)
      end
    end

    def self.checkout_branch(branch : String, repository : String, working_directory : String)
      path = repository_path(repository, working_directory)
      result = repo_operation(path) do
        run_git(path, {"checkout", "--force", branch}, raises: true)
      end
      result.output.to_s.strip
    end

    def self.fetch(repository : String, working_directory : String)
      path = repository_path(repository, working_directory)
      result = operation_lock(path).synchronize do
        run_git(path, {"fetch", "--all"}, raises: true)
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
      result = repository_lock(repo_dir).write do
        fetch(repository, working_directory)
        _checkout(repo_dir, branch, raises: raises, force: true)
        run_git(repo_dir, {"pull"}, raises: raises)
        _checkout(repo_dir, "HEAD", raises: raises)
      end

      Result::Command.new(
        exit_code: result.status.exit_code,
        output: result.output.to_s,
      )
    end

    def self.get_remote_url(
      repository : String,
      working_directory : String,
      raises : Bool = true
    ) : URI
      repo_dir = repository_path(repository, working_directory)
      uri = basic_operation(repo_dir) do
        run_git(repo_dir, {"remote", "get-url", "origin"}, raises: raises)
      end.output.to_s.strip
      URI.parse(uri)
    end

    def self.set_remote_url(
      repository : String,
      repository_uri : String | URI,
      working_directory : String,
      raises : Bool = true
    )
      repo_dir = repository_path(repository, working_directory)
      repository_uri = repository_uri.to_s if repository_uri.is_a? URI
      repository_lock(repo_dir).write do
        run_git(repo_dir, {"remote", "set-url", "origin", repository_uri}, raises: raises)
      end
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

      repository_uri = repository_uri.rchop('/')

      # The call to write here ensures that no other operations are occuring on
      # the repository at this time.
      repository_lock(repo_dir).write do
        # Ensure the repository directory exists (it should)
        Dir.mkdir_p working_directory
        repository_path = File.join(working_directory, repository)

        # Check if there's an existing repo
        current = begin
          if Dir.exists?(File.join(repository_path, ".git"))
            current_branch(repository_path)
          end
        rescue e : Error::Git
          Log.warn(exception: e) { "failed to query current branch from #{repository}, proceeding with clone" }
          nil
        end

        # Check the existing credentials (if any) are correct
        unless current.nil?
          uri = get_remote_url(repository, working_directory)
          unless uri.password == password && uri.user == username
            # Update the remote if the credentials do not match
            uri.user = username
            uri.password = password
            set_remote_url(repository, uri, working_directory)
          end
        end

        if current
          if current != branch
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
      args = args.to_a if args.is_a? Tuple
      git_args = git_args.to_a if git_args.is_a? Tuple
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
