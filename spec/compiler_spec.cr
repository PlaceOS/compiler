require "./spec_helper"
require "file_utils"

module PlaceOS
  describe Compiler do
    it "should compile a driver" do
      # Test the executable is created
      result = Compiler.build_driver(
        "drivers/place/private_helper.cr",
        "private_drivers",
        commit: SPEC_COMMIT
      )

      pp! result unless result.success?

      result.exit_code.should eq(0)
      File.exists?(result.path).should be_true

      # Check it functions as expected
      io = IO::Memory.new
      Process.run(result.path, {"-h"},
        input: Process::Redirect::Close,
        output: io,
        error: io
      )
      io.to_s.starts_with?("Usage:").should be_true
    end

    it "should list compiled versions" do
      files = Compiler.compiled_drivers("drivers/place/private_helper.cr")

      files.size.should eq Dir.children(Compiler.binary_dir).count { |f| !f.includes?('.') && f.starts_with?("drivers_place_private_helper") }
      files.first.should start_with("drivers_place_private_helper")
    end

    it "should clone and install a repository" do
      Compiler.clone_and_install("rwlock", "https://github.com/spider-gazelle/readers-writer")
      File.file?(File.expand_path("./repositories/rwlock/shard.yml")).should be_true
    end

    it "should clone and install a repository branch" do
      Compiler.clone_and_install("ulid", "https://github.com/place-labs/ulid", branch: "test")
      File.file?(File.expand_path("./repositories/ulid/shard.yml")).should be_true
      File.directory?(File.expand_path("./repositories/ulid/src")).should be_true
      Compiler::Git.current_branch(File.expand_path("./repositories/ulid")).should eq "test"
    end

    it "should compile a private driver" do
      # Clone the private driver repo
      Compiler.clone_and_install("private_drivers", "https://github.com/placeos/private-drivers.git")
      File.file?(File.expand_path("./repositories/private_drivers/drivers/place/private_helper.cr")).should be_true

      # Test the executable is created
      result = Compiler.build_driver(
        "drivers/place/private_helper.cr",
        "private_drivers",
        commit: SPEC_COMMIT
      )

      pp! result unless result.success?

      result.exit_code.should eq(0)
      File.exists?(result.path).should be_true

      # Check it functions as expected
      io = IO::Memory.new
      Process.run(result.path, {"-h"},
        input: Process::Redirect::Close,
        output: io,
        error: io
      )
      io.to_s.starts_with?("Usage:").should be_true

      # Delete the file
      File.delete(result.path)
    end

    it "should compile a private spec" do
      # Clone the private driver repo
      Compiler.clone_and_install("private_drivers", "https://github.com/placeos/private-drivers.git")
      # Test the executable is created
      result = Compiler.build_driver(
        "drivers/place/private_helper_spec.cr",
        repository: "private_drivers",
        git_checkout: false,
        commit: SPEC_COMMIT
      )

      spec_executable = result.path

      result.exit_code.should eq(0)
      File.exists?(spec_executable).should be_true

      result = Compiler.build_driver(
        "drivers/place/private_helper.cr",
        repository: "private_drivers",
        git_checkout: false,
        commit: SPEC_COMMIT
      )

      # Ensure the driver we want to test exists
      executable = result.path
      File.exists?(executable).should be_true

      # Check it functions as expected SPEC_RUN_DRIVER
      io = IO::Memory.new
      exit_code = Process.run(spec_executable,
        env: {"SPEC_RUN_DRIVER" => executable},
        input: Process::Redirect::Close,
        output: io,
        error: io
      ).exit_code

      puts io.to_s unless result.success?
      exit_code.should eq(0)

      # Delete the file
      FileUtils.rm(Dir.glob "#{executable}*")
      FileUtils.rm(Dir.glob "#{spec_executable}*")
    end
  end
end
