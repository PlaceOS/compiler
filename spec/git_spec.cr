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

    describe ".commits" do
      it "lists the revisions of a file in a repository" do
        changes = Git.commits("shard.yml", repository, working_directory, 200)
        changes.should_not be_empty
        changes.map(&.subject).should contain("simplify dependencies")
      end

      it "fetches entire commit history of a file on a branch" do
        repo = "compiler"
        repo_uri = "https://github.com/placeos/compiler"
        branch = "test-fixture"
        checked_out_commit = "f7c6d8fb810c2be78722249e06bbfbda3d30d355"
        expected_commit = "d37c34a49c96a2559408468b2b9458867cbf1329"
        repository_directory = File.join(working_directory, repo)
        Git.clone(
          repository: repo,
          repository_uri: repo_uri,
          working_directory: working_directory,
        )
        Git._checkout(repository_directory, checked_out_commit)
        changes = Git.commits("README.md", repo, working_directory, 200, branch)
        changes.map(&.commit).should contain(expected_commit)
      end
    end

    describe ".repository_commits" do
      it "lists the revisions of a repository" do
        changes = Git.repository_commits(repository, working_directory, 200)
        changes.should_not be_empty
        changes.map(&.subject).includes?("simplify dependencies").should be_true
      end

      it "fetches entire commit history of a branch" do
        repo = "compiler"
        repo_uri = "https://github.com/placeos/compiler"
        branch = "test-fixture"
        checked_out_commit = "f7c6d8fb810c2be78722249e06bbfbda3d30d355"
        expected_commit = "d37c34a49c96a2559408468b2b9458867cbf1329"
        repository_directory = File.join(working_directory, repo)
        Git.clone(
          repository: repo,
          repository_uri: repo_uri,
          working_directory: working_directory,
        )
        Git._checkout(repository_directory, checked_out_commit)
        changes = Git.repository_commits(repo, working_directory, 200, branch)
        changes.map(&.commit).should contain(expected_commit)
      end
    end

    describe "remote url" do
      it ".get_remote_url" do
        Git.get_remote_url(repository, working_directory).should eq URI.parse("https://github.com/placeos/private-drivers.git")
      end

      it ".set_remote_url" do
        existing_remote = Git.get_remote_url(repository, working_directory)
        new_remote = URI.parse("https://github.com/this-repo/doesnt-exist.git")
        begin
          Git.set_remote_url(repository, new_remote, working_directory)
          Git.get_remote_url(repository, working_directory).should eq new_remote
        ensure
          Git.set_remote_url(repository, existing_remote, working_directory)
        end
      end
    end

    describe ".current_repository_commit" do
      it "fetches checked out commit of repo" do
        expected_commit = "0bcfa6e4a9ad832fadf799f15f269608d61086a7"
        Git._checkout(repository_path, expected_commit)
        Git.current_repository_commit(repository, working_directory).should eq expected_commit
      end
    end

    describe ".current_file_commit" do
      it "fetches checked out commit of file" do
        file = "README.md"
        checked_out_commit = "fe335884cbb8d7bc843d33fa7b97d7a306b35208"
        expected_commit = "121a3593dbf1b83373d11e8ff8f1150c14e67fe9"
        Git._checkout(repository_path, checked_out_commit)
        Git.current_file_commit(file, repository, working_directory).should eq expected_commit
      end
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

      it "will check out a file, then restore to a repo state where it does not exist" do
        file = "drivers/aca/private_helper.cr"
        path = File.join(repository_path, file)
        File.exists?(path).should be_false

        Git.checkout_file(file, repository, working_directory, commit: "9e5c982e2aac06e1e10349fe8352109c138d7f23") do
          File.exists?(path).should be_true
        end

        File.exists?(path).should be_false
      end
    end
  end
end
