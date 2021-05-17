require "./spec_helper"

module PlaceOS::Compiler
  describe Helper do
    repository = "private_drivers"
    file = "drivers/place/private_helper.cr"
    working_directory = Compiler.repository_dir

    it "should list drivers" do
      drivers = Helper.drivers(repository, working_directory)
      (drivers.size > 0).should be_true
      drivers.includes?(file).should be_true
    end
  end
end
