require "./compiler"
require "./error"
require "./git"

module PlaceOS::Compiler
  module Helper
    extend self

    # Returns a list of repository paths
    def repositories : Array(String)
      Compiler.repositories
    end

    # Returns a list of driver source file paths in a repository
    # defaults to PlaceOS repository, i.e. this one
    def drivers(repository : String, working_directory : String) : Array(String)
      Dir.cd(Git.repository_path(repository, working_directory)) do
        Dir.glob("drivers/**/*.cr").select do |file|
          # Must not be a spec and there must be a class that includes `placeos-driver` directly
          !file.ends_with?("_spec.cr") && File.open(file) do |f|
            f.each_line.any? &.includes?("PlaceOS::Driver")
          rescue
            false
          end
        end
      end
    end

    # Returns a list of compiled driver file paths
    # (across all repositories)
    def compiled_drivers(id : String? = nil) : Array(String)
      Compiler.compiled_drivers(id)
    end

    # Check if a version of a driver exists
    def compiled?(driver_file : String, commit : String, id : String? = nil) : Bool
      File.exists?(driver_binary_path(driver_file, commit, id))
    end

    # Generates path to a driver executable
    def driver_binary_path(driver_file : String, commit : String, id : String? = nil)
      File.join(Compiler.bin_dir, driver_binary_name(driver_file, commit, id))
    end

    # Generates the name of a driver binary
    def driver_binary_name(driver_file : String, commit : String, id : String? = nil)
      Compiler.executable_name(driver_file, commit, id)
    end

    # Deletes a compiled driver
    # not providing a commit deletes all versions of the driver
    def delete_driver(
      driver_file : String,
      repository : String,
      working_directory : String,
      commit : String? = nil,
      id : String? = nil
    ) : Array(String)
      # Check repository to prevent abuse (don't want to delete the wrong thing)
      repository_path = Git.repository_path(repository, working_directory)
      Git.checkout(driver_file, repository, working_directory, commit || "HEAD") do
        return [] of String unless File.exists?(File.join(repository_path, driver_file))
      end

      files = if commit
                [driver_binary_name(driver_file, commit, id)]
              else
                compiled_drivers(id)
              end

      files.each do |file|
        File.delete(File.join(Compiler.bin_dir, file))
      end

      files
    end
  end
end
