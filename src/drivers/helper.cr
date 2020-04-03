require "./command_failure"
require "./compiler"
require "./git_commands"

module PlaceOS::Drivers
  module Helper
    extend self

    # Returns a list of repository paths
    def repositories : Array(String)
      Compiler.repositories
    end

    # Returns a list of driver source file paths in a repository
    # defaults to PlaceOS repository, i.e. this one
    def drivers(repository : String? = nil) : Array(String)
      Dir.cd(get_repository_path(repository)) do
        Dir.glob("drivers/**/*.cr").select do |file|
          !file.ends_with?("_spec.cr")
        end
      end
    end

    # Returns a list of compiled driver file paths
    # (across all repositories)
    def compiled_drivers : Array(String)
      Compiler.compiled_drivers
    end

    # Check if a version of a driver exists
    def compiled?(driver : String, commit : String) : Bool
      File.exists?(driver_binary_path(driver, commit))
    end

    # Generates path to a driver executable
    def driver_binary_path(driver, commit)
      File.join(Compiler.bin_dir, Compiler.executable_name(driver, commit))
    end

    # Repository commits
    #
    # [{commit:, date:, author:, subject:}, ...]
    def repository_commits(repository : String? = nil, count = 50)
      GitCommands.repository_commits(get_repository_path(repository), count)
    end

    # Returns the latest commit hash for a repository
    def repository_commit_hash(repository : String? = nil)
      repository_commits(repository, 1).first[:commit]
    end

    # File level commits
    # [{commit:, date:, author:, subject:}, ...]
    def commits(file_path : String, repository : String? = nil, count = 50)
      GitCommands.commits(file_path, count, get_repository_path(repository))
    end

    # Returns the latest commit hash for a file
    def file_commit_hash(file_path : String, repository : String? = nil)
      commits(file_path, repository, 1).first[:commit]
    end

    # Takes a file path with a repository path and compiles it
    # [{exit_status:, output:, driver:, version:, executable:, repository:}, ...]
    def compile_driver(driver : String, repository : String? = nil, commit = "HEAD")
      Compiler.build_driver(driver, commit, get_repository_path(repository))
    end

    # Deletes a compiled driver
    # not providing a commit deletes all versions of the driver
    def delete_driver(driver : String, repository : String? = nil, commit = nil) : Array(String)
      # Check repository to prevent abuse (don't want to delete the wrong thing)
      repository = get_repository_path(repository)
      GitCommands.checkout(driver, commit || "HEAD", repository) do
        return [] of String unless File.exists?(File.join(repository, driver))
      end

      files = if commit
                [Compiler.executable_name(driver, commit)]
              else
                Compiler.compiled_drivers(driver)
              end

      files.each do |file|
        File.delete(File.join(Compiler.bin_dir, file))
      end
      files
    end

    def get_repository_path(repository : String?) : String
      if repository
        repo = File.expand_path(File.join(Compiler.repository_dir, repository))
        valid = repo.starts_with?(Compiler.repository_dir) && repo != "/" && repository.size > 0 && !repository.includes?("/") && !repository.includes?(".")
        raise "invalid repository: #{repository}" unless valid
        repo
      else
        Compiler.drivers_dir
      end
    end
  end
end