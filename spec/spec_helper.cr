require "spec"
require "file_utils"

require "../src/drivers"

Spec.before_suite do
  # Clone the private drivers
  PlaceOS::Drivers::Compiler.clone_and_install(
    "private_drivers",
    "https://github.com/placeos/private-drivers"
  )
end

Spec.after_suite do
  FileUtils.rm_rf("./repositories") if ENV["TRAVIS"]?
end
