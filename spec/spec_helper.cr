require "spec"

require "../src/drivers"

Spec.before_suite do
  # Clone the private drivers
  PlaceOS::Drivers::Compiler.clone_and_install(
    "private_drivers",
    "https://github.com/placeos/private-drivers"
  )
end
