require "./spec_helper"
require "yaml"

module PlaceOS::Compiler
  describe Git do
    repository = "private_drivers"
    working_directory = Compiler.repository_dir
    repository_path = Git.repository_path(repository, working_directory)
    readme = File.join(repository_path, "README.md")

    current_title = "# Private PlaceOS Drivers\n"
    old_title = "# Private Engine Drivers\n"

    it "should list files in the repository" do
      files = Git.ls(repository, working_directory)
      files.should_not be_empty
      files.includes?("shard.yml").should be_true
    end

    it "should list the revisions to a file in a repository" do
      changes = Git.commits("shard.yml", repository, working_directory, 200)
      changes.should_not be_empty
      changes.map(&.subject).includes?("simplify dependencies").should be_true
    end

    it "should list the revisions of a repository" do
      changes = Git.repository_commits(repository, working_directory, 200)
      changes.should_not be_empty
      changes.map(&.subject).includes?("simplify dependencies").should be_true
    end

    describe ".branches" do
      it "lists branches" do
        branches = Git.branches(repository, working_directory)
        branches.should contain("master")
      end
    end

    describe ".checkout_file" do
      it "will checkout a particular revision of a file and then restore it" do
        # Check the current file
        title = File.open(readme, &.gets('\n'))
        title.should eq(current_title)

        # Process a particular commit
        Git.checkout_file("README.md", repository, working_directory, commit: "0bcfa6e4a9ad832fadf799f15f269608d61086a7") do
          title = File.open(readme, &.gets('\n'))
          title.should eq(old_title)
        end

        # File should have reverted
        title = File.open(readme, &.gets('\n'))
        title.should eq(current_title)
      end

      it "will checkout a file and then restore it on error" do
        # Check the current file
        title = File.open(readme, &.gets('\n'))
        title.should eq(current_title)

        # Process a particular commit
        expect_raises(Exception, "something went wrong") do
          Git.checkout_file("README.md", repository, working_directory, commit: "0bcfa6e4a9ad832fadf799f15f269608d61086a7") do
            title = File.open(readme, &.gets('\n'))
            title.should eq(old_title)

            raise "something went wrong"
          end
        end

        # File should have reverted
        title = File.open(readme, &.gets('\n'))
        title.should eq(current_title)
      end
    end
  end
end
