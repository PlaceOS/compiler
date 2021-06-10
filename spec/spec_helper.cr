require "placeos-log-backend"
require "spec"
require "file_utils"

require "../src/placeos-compiler"

SPEC_COMMIT = ENV["COMPILER_SPEC_COMMIT"]? || "HEAD"

Spec.before_suite do
  ::Log.setup("*", backend: PlaceOS::LogBackend.log_backend, level: :debug)

  # Clone the private drivers
  PlaceOS::Compiler.clone_and_install(
    "private_drivers",
    "https://github.com/placeos/private-drivers"
  )
end

Spec.after_suite do
  FileUtils.rm_rf("./repositories")
end
